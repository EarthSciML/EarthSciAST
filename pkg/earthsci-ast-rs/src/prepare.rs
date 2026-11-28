//! The deterministic-per-document **build pipeline** — what
//! [`crate::problem::esm_problem`] runs before it compiles a right-hand side.
//!
//! This module used to be the public `prepare` / `Prepared` entry point.
//! `esm-libraries-spec.md` §2.5.1 replaces that: `prepare` and `Prepared` are
//! the same concept as `EsmProblem` under a local name, and construction absorbs
//! them rather than sitting beside them. What survives here is the pipeline
//! itself ([`run_build_pipeline`], crate-internal) and the two things a caller
//! genuinely reaches for — the build-time provider contract
//! ([`DataProvider`]) and the build-observability seam ([`PreparePhase`],
//! [`PrepareProgress`]), both extension seam under `API_SPEC.md` §3, neither
//! stable API.
//!
//! Runs everything deterministic-per-document ONCE — pushdown rewrite →
//! loader extent discovery → typed load → provider materialization →
//! build-time coordinate evaluation → value-invention → member-factor feedback
//! → gated pre-sliced fetch → dependency-ordered observed-graph evaluation —
//! and returns a [`PreparedBuild`] whose [`PreparedBuild::fields`] map holds the
//! build-time fields. This is the entry point the isrm.esm runner drives;
//! it never integrates.
//!
//! **Extent discovery** runs before the typed load because it CLOSES
//! metaparameters: a loader whose record count is only knowable after the
//! table is read declares `extent: {"metaparameter": "N_REC"}`, its providers
//! are sampled once up front (never twice), and the surviving length binds the
//! metaparameter every dependent index set is sized by. The caller no longer
//! counts rows and passes the number in — see
//! [`DataProvider::extent_metaparameter`].
//!
//! Those arrows are also [`PreparePhase`], and a host can watch them go by:
//! [`crate::problem::ProblemOptions::progress`] is the build-time counterpart of
//! [`crate::simulate::SolveOptions::progress`], down to sharing its
//! [`Flow`]. It exists because a document with no ODEs never reaches the
//! solver, so a dispatched static evaluation had no observer at all — no
//! progress bar, no cancel button, and no way to enforce a resource cap on a
//! run that takes a quarter of an hour. **Progress observation is
//! binding-local**, not a conformance surface: it changes no result, produces
//! no artifact the fixtures compare, and the Julia and Python `prepare` have no
//! equivalent (nor a `verbose`); the cross-binding observability contract is
//! `BuildInspection`, which carries VALUES and is pinned by CONFORMANCE_SPEC
//! §5.8. A binding that wants this may mirror it or not, freely.
//!
//! `pushdown_rewrite: true` opts into the automatic projection-pushdown
//! desugar ([`crate::pushdown_rewrite::desugar_pushdown`]) at this public
//! entry point, exactly as in Julia/Python:
//!
//! * the rewrite runs on the RAW authored document BEFORE the typed parse
//!   (the raw-JSON design note in [`crate::pushdown_rewrite`]). NOTE the
//!   name-rewriting trap the Julia binding had (its flattener rewrites
//!   coupling-fed references in equations but not in variable `expression`
//!   fields, so the pattern no longer matches post-flatten) does NOT apply
//!   here: this Rust path never flattens — it selects the single authored
//!   model and resolves the coupling `variable_map` by ALIASING the provider
//!   arrays under the model-local names, so the pattern is always detected on
//!   the authored spelling;
//! * the engine derives every provider gate from the rewrite's OWN record
//!   (`metadata.x_esd.pushdown.gated_select`) + the document coupling — the
//!   caller hand-authors NO gate and implements no selection plumbing;
//! * a `providers` entry the coupling routes onto a rewritten array is
//!   DEFERRED and fetched pre-sliced to the invented support set after
//!   value-invention has materialised the set's members (pushdown hook 2);
//! * the derived set's `member_factor` parameter is filled with the
//!   materialised member ids (pushdown hook 1), so the generated
//!   `pd_cell__*[c] = index(F, index(member_factor, c))` gathers resolve;
//! * VI key/overlap factor observeds that are themselves join-free
//!   observed expressions (the in-model LCC projections `X`/`Y` over raw
//!   `emis_lon`/`emis_lat`) are evaluated through the FULL expression
//!   evaluator ahead of value-invention — the Rust analogue of Julia's
//!   `_derive_binning_coords` general-eval seeding and Python's
//!   `_binning_coord_arrays(producer_seed_nodes=…)`. The deliberately tiny
//!   `_vi_eval` op set is untouched.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fmt;
use std::path::PathBuf;
use std::sync::Arc;

use ndarray::{ArrayD, Axis, IxDyn, Slice};
use serde_json::Value as JsonValue;

use crate::classification::DeclaredRank;
use crate::compile_error::CompileError;
use crate::faq::resolve_expr_ranges_with_extents;
use crate::parse::LoadOptions;
pub use crate::provider::AxisSel;
use crate::provider::DataProvider;
use crate::pushdown_rewrite::{
    GateAxis, ProviderGate, desugar_pushdown, pushdown_coupling_pairs, pushdown_provider_gates,
};
use crate::simulate::{KeyMatch, KeyPolicy, KeyResolver, SimulateError, namespace_scope};
use crate::simulate_array::{
    ArrMap, BuildInput, BuiltVariables, ConstArrayScope, MemberFactorColumn, NormalizedModel,
    StandaloneScope, Value as EvalValue, member_factor_columns, run_value_invention_in_scope,
};
use crate::template_imports::resolve_template_machinery;
use crate::types::{Expr, IndexSet, Model, VariableType};
use indexmap::IndexMap;

/// What a [`crate::problem::ProblemOptions::progress`] observer wants the build
/// to do next —
/// the SAME type a [`crate::simulate::SolveOptions::progress`] observer
/// returns.
///
/// Deliberately shared rather than mirrored: a host that already drives a solve
/// through [`Flow::Cancel`] should not have to learn a second cancellation
/// idiom to drive a build.
pub use crate::simulate::Flow;

/// A gated provider deferred by [`BuildState::inject_providers`]: its key, the
/// provider itself, and the gate its fetch is planned against.
type GatedProvider = (String, Box<dyn DataProvider>, ProviderGate);

/// An uncoded build failure of the pipeline, as the compile path reports
/// one.
fn err(msg: impl Into<String>) -> SimulateError {
    SimulateError::Compile(CompileError::build_err(msg))
}

/// A stage's typed refusal: a coded one keeps its identity (and its code), an
/// uncoded one is reported with `context` naming what the stage was doing.
fn stage_err(context: impl fmt::Display, e: CompileError) -> SimulateError {
    if e.code().is_some() {
        SimulateError::Compile(e)
    } else {
        err(format!("{context}: {e}"))
    }
}

// --------------------------------------------------------------------------- //
// Progress observation.
// --------------------------------------------------------------------------- //

/// Which stage of the build [`crate::problem::esm_problem`] is in when it reports.
///
/// These are the document-independent stages of the build pipeline, in
/// the order it runs them, and they are exactly the stages
/// [`crate::problem::ProblemOptions::verbose`] already narrates — the observer did not invent a
/// structure, it made the existing one addressable.
///
/// **The stages are nowhere near equal in cost.** On the InMAP ISRM document a
/// [`PreparePhase::GatedFetch`] is tens of gigabytes over the network and
/// [`PreparePhase::Observeds`] is a source-by-receptor contraction, while
/// [`PreparePhase::Rewrite`] and [`PreparePhase::Load`] are milliseconds. A
/// host that renders `index() / COUNT` as a percentage will show a bar that
/// sprints to 60% and then sits still for ten minutes. Drive the bar from
/// [`PrepareProgress::fraction`] *within* the reported phase and name the phase
/// (and [`PrepareProgress::item`]) beside it instead — the same advice
/// [`crate::simulate::Progress`] gives about a stiff solve's non-linear `t`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum PreparePhase {
    /// The projection-pushdown desugar over the raw authored document.
    Rewrite,
    /// The typed parse of the (possibly rewritten) document.
    Load,
    /// Eager materialization of the un-gated CONST providers, one unit each.
    ConstProviders,
    /// The producer-seeded join-free coordinate closure, one unit per observed.
    Coordinates,
    /// Value invention — the graph deriving its own support set.
    ValueInvention,
    /// Feeding the invented member ids back as each derived set's
    /// `member_factor`, one unit per derived index set.
    MemberFactors,
    /// The post-value-invention pre-sliced fetch of the gated providers. One
    /// unit per REQUEST, which is one per provider unless
    /// [`crate::problem::ProblemOptions::gated_fetch_batch`] splits it further.
    GatedFetch,
    /// Dependency-ordered evaluation of the observed graph, one unit per
    /// observed.
    Observeds,
}

impl PreparePhase {
    /// Every phase, in pipeline order.
    pub const ALL: [PreparePhase; 8] = [
        PreparePhase::Rewrite,
        PreparePhase::Load,
        PreparePhase::ConstProviders,
        PreparePhase::Coordinates,
        PreparePhase::ValueInvention,
        PreparePhase::MemberFactors,
        PreparePhase::GatedFetch,
        PreparePhase::Observeds,
    ];

    /// How many phases there are, for a host laying out a stage list.
    pub const COUNT: usize = Self::ALL.len();

    /// 0-based position in the pipeline. See the type's note before turning
    /// this into a percentage.
    pub fn index(self) -> usize {
        Self::ALL.iter().position(|p| *p == self).unwrap_or(0)
    }

    /// A human-readable phase name, as it appears in a cancellation message.
    pub fn label(self) -> &'static str {
        match self {
            PreparePhase::Rewrite => "the pushdown rewrite",
            PreparePhase::Load => "the typed load",
            PreparePhase::ConstProviders => "const provider materialization",
            PreparePhase::Coordinates => "build-time coordinate evaluation",
            PreparePhase::ValueInvention => "value invention",
            PreparePhase::MemberFactors => "member-factor feedback",
            PreparePhase::GatedFetch => "the gated fetch",
            PreparePhase::Observeds => "observed-graph evaluation",
        }
    }
}

impl fmt::Display for PreparePhase {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.label())
    }
}

/// How far along an in-flight build is, handed to
/// [`crate::problem::ProblemOptions::progress`] at every phase boundary AND at every unit of
/// work inside the two phases that dominate a large build.
///
/// A report is delivered BEFORE the unit it names is done, so `item` is what
/// `prepare` is about to spend its time on — which is the useful thing to show,
/// and the only placement at which returning [`Flow::Cancel`] avoids the work
/// rather than following it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PrepareProgress<'a> {
    /// The stage of the build this report comes from.
    pub phase: PreparePhase,
    /// Units of work already finished in this phase.
    pub done: usize,
    /// Units of work this phase will do, when that is knowable before it
    /// starts. `None` for a phase that is a single indivisible step.
    pub total: Option<usize>,
    /// What the phase is about to work on: an observed's name, a provider key,
    /// a derived index set. Empty when the report is a phase boundary rather
    /// than an item.
    pub item: &'a str,
}

impl PrepareProgress<'_> {
    /// Fraction of THIS PHASE's work completed, clamped to `[0, 1]`.
    ///
    /// `0.0` when the phase has no countable work, rather than a NaN, so a host
    /// can feed it to a bar without a guard. This is deliberately not a
    /// whole-build fraction: see [`PreparePhase`] on why the library refuses to
    /// invent phase weights it cannot know for a document it has not run.
    pub fn fraction(&self) -> f64 {
        match self.total {
            Some(t) if t > 0 => (self.done as f64 / t as f64).clamp(0.0, 1.0),
            _ => 0.0,
        }
    }
}

/// A build progress observer. See [`crate::problem::ProblemOptions::progress`].
///
/// Unconditionally `Send + Sync`, unlike [`crate::simulate::ProgressFn`], which
/// drops the bound on `wasm32` for a `js_sys::Function` observer: the whole
/// `prepare` module is `#[cfg(not(target_arch = "wasm32"))]`, so there is no
/// wasm host to accommodate and no reason to make native callers pay for one.
pub type PrepareProgressFn = Arc<dyn Fn(&PrepareProgress<'_>) -> Flow + Send + Sync>;

/// What one run of the pipeline reads: the Problem's options, borrowed, and
/// the two things construction decides for it.
pub(crate) struct BuildContext<'o> {
    /// The options the Problem is being built with. The pipeline reads
    /// `model_name`, `metaparameters`, `base_path`, `pushdown_rewrite`, `p`
    /// (scalar overrides, exact or bare names, baked into the build),
    /// `verbose`, `progress`, `gated_fetch_batch` and `observed_cone`.
    pub problem: &'o crate::problem::ProblemOptions,
    /// The construction sample time (`sample_time`, else the start of the
    /// time span): the `t` every build-time observed is evaluated at, as the
    /// static route evaluates it.
    pub t0: f64,
    /// Stop at the first evaluation that is interpreted PER CELL and hand it
    /// back as [`PreparedBuild::refused`] — set when the Problem's compiler is
    /// strict (esm-libraries-spec §2.5.10), so a `native` build refuses the
    /// document naming the observed instead of walking it. The walk itself
    /// stops at its first cell, so the refusal costs one cell, not the field.
    pub refuse_per_cell: bool,
}

/// The product of [`run_build_pipeline`]: every build-time-evaluable observed of the
/// prepared document, materialized through the document's own graph, plus the
/// value-invention products the contract record reports.
pub struct PreparedBuild {
    /// The (possibly rewritten) raw document.
    pub doc: JsonValue,
    /// The prepared model's name, or `None` when the build is the whole
    /// document: several models and none selected, built as one
    /// dot-namespaced system whose names (`Model.var`) are already qualified.
    pub model_name: Option<String>,
    /// [`Self::doc`] loaded, closed over the caller's metaparameters and the
    /// discovered loader extents that it still declares: the one typed form
    /// of the prepared document, which the Problem compiles.
    pub(crate) file: crate::EsmFile,
    /// The flattened system the pipeline built, when it is `flatten` of
    /// [`Self::file`] — the whole-document build, or a model built alone in a
    /// document that is that model and nothing else
    /// ([`builds_alone_as_itself`]) — so the compile path may use it in place
    /// of flattening that document again, and the pipeline's value invention
    /// in place of running its own. `None` for a model built alone out of a
    /// larger document.
    pub(crate) flattened: Option<crate::flatten::FlattenedSystem>,
    /// What the Problem keeps of this build: the observed fields, the
    /// value-invention members and extents, the gated provider keys and the
    /// built variables. The rest of [`crate::problem::BuildProducts`] is
    /// construction's to fill.
    pub(crate) products: crate::problem::BuildProducts,
    /// Data-fed parameter name (model-local) → the values its provider
    /// supplied, as the build read them. A data-fed parameter is not an
    /// observed, so it is not in `products.fields`, but it is as observable:
    /// an inline-test assertion or an `observed_field` request may name it
    /// (finding F43).
    pub data_fields: HashMap<String, ArrayD<f64>>,
    /// Every evaluation the pipeline performed, in the order it performed
    /// them — what the Problem's compiler report shows for this route.
    pub rules: Vec<PipelineRule>,
    /// The per-cell evaluation that stopped the build, when
    /// [`BuildContext::refuse_per_cell`] was set. `fields` then holds only
    /// what was evaluated before it.
    pub refused: Option<PipelineRule>,
    /// Whether [`crate::problem::ProblemOptions::observed_cone`] narrowed a non-empty
    /// observed graph. `products.fields` is then this build's answer even when
    /// it is empty (the request named only a data-fed parameter), so nothing
    /// re-evaluates the document to fill it.
    pub(crate) observed_cone_applied: bool,
}

/// One evaluation the build pipeline performed, and HOW: by the reference
/// evaluator over whole arrays, on a standalone tape, interpreted per cell by
/// the oracle, or — for value
/// invention — by the relational engine.
///
/// The pipeline evaluates the document's observed graph with the reference
/// evaluator whatever compiler the Problem names, so these records are how
/// that route reaches the compiler report (esm-libraries-spec §2.5.10: "the
/// materialization of constants and static observeds at construction" is
/// under the refusal).
#[derive(Clone, Debug)]
pub(crate) struct PipelineRule {
    /// The observed (model-local), or the value-invention producer id.
    pub name: String,
    /// `"build-time observed"` or `"value invention"`.
    pub kind: &'static str,
    /// Which evaluator served it.
    pub route: Route,
}

/// The evaluator that served one [`PipelineRule`] — what its compiler-report
/// tier names.
#[derive(Clone, Debug)]
pub(crate) enum Route {
    /// The reference evaluator over whole arrays, no `faq` walked per cell
    /// (tier `"vectorized"`).
    Whole,
    /// A standalone tape: under a strict compiler, an observed the reference
    /// evaluator would walk per cell is lowered on the tape and run once
    /// (tier `"taped"`).
    Tape,
    /// The reference evaluator, walking cells one at a time, and why (tier
    /// `"oracle"`). The one route a strict compiler refuses.
    PerCell(String),
    /// Value invention's relational engine (tier `"relational"`): the
    /// producer's member set, computed ONCE at setup from build-time factors —
    /// a `continuous` producer is refused before it runs (CONFORMANCE_SPEC
    /// §5.7.6 guard 2). There is no compiled form of a set to decline to, and
    /// the array runtime's own build runs the same pass under every compiler,
    /// so it is neither a fallback nor refused.
    Relational,
}

/// Why an observed was walked per cell.
const PER_CELL_FAQ: &str = "the build pipeline evaluated it through the reference evaluator, \
    which walks a `faq` body once per cell";
/// Why a causal self-reference is walked per cell.
const PER_CELL_RECURRENCE: &str = "a causal self-reference (esm-spec §4.3.1.1), which the \
    build pipeline sweeps cell by cell through the reference evaluator";

// --------------------------------------------------------------------------- //
// Dependency order over the observeds.
// --------------------------------------------------------------------------- //

/// The dependency summaries of the observed definitions `defs`
/// ([`crate::dependency`]). A state of `model` (an unknown that is not an
/// observed) and a parameter in `runtime_fed` (one a time-varying provider
/// feeds at run time, [`run_prepare`]) are the inputs that vary: the
/// build-time observed pass does not evaluate an observed that reads one,
/// directly or through another observed, because neither has its value at
/// build time. Those are evaluated at run time like every other observed, by
/// the compiler the Problem names. A self-read is dropped: it is not an edge
/// to another observed.
fn observed_dependencies(
    model: &Model,
    defs: &HashMap<String, Expr>,
    runtime_fed: &HashSet<String>,
) -> crate::dependency::DependencySummaries {
    use crate::dependency::{DependencySummaries, Leaf, Reads};
    let class = crate::classification::Classification::of(model);
    DependencySummaries::new(
        defs.iter()
            .map(|(n, e)| (n.clone(), Reads::of(e).without(n))),
        |name| match model.variables.get(name) {
            Some(var) if var.var_type == VariableType::Unknown && !class.is_observed(name) => {
                Leaf::State
            }
            _ if runtime_fed.contains(name) => Leaf::Discrete,
            _ => Leaf::Const,
        },
    )
}

/// Dependency order over observed definitions: an observed follows every
/// observed it names. A cycle is a malformed model and is a hard error.
fn observed_order(
    deps: &crate::dependency::DependencySummaries,
) -> Result<Vec<String>, SimulateError> {
    // Name the CYCLE, not the residue: the whole value of this diagnostic is
    // the path (esm-spec §4.9.6).
    if let Some(cycle) = deps.cycle() {
        return Err(err(format!(
            "observed_cycle: dependency cycle among observed variables: {}. Each is defined \
             in terms of the next, so no evaluation order satisfies every definition \
             (esm-spec §4.9.6). `esm validate` reports this cycle before any build.",
            cycle.join(" -> ")
        )));
    }
    Ok(deps.order().to_vec())
}

/// name → defining expression, for every OBSERVED unknown of `model` that this
/// pass EVALUATES (esm-spec §6.3.1).
///
/// From esm 1.0.0 an observed's definition is the RHS of the equation whose LHS
/// is the bare variable, not a `variables[v].expression` field — and that is
/// also where a VALUE-INVENTION producer has always lived. Before the two
/// merged, the field a definition sat in told them apart for free; now it does
/// not, so the relational outputs are filtered out explicitly. Handing one to
/// the array evaluator is not a small error: the `distinct` producer the
/// projection-pushdown desugar emits carries a `{"op": "true"}` body, which has
/// no evaluation rule at all (`unevaluable_operator`), because the relational
/// engine — not the evaluator — is what materializes it.
fn observed_defs(model: &Model) -> HashMap<String, Expr> {
    crate::classification::observed_definitions(model)
        .into_iter()
        .filter(|(_, def)| !crate::value_invention::is_value_invention_expr(def))
        .collect()
}

/// How the build spells the names of the model it builds, and so how a key
/// from outside the document reaches one of them.
///
/// Provider keys, gate targets, supplied arrays and scalar overrides all come
/// spelled `"<ModelPath>.<var>"` or bare, while the built model spells its
/// names one of two ways, and each way has its rule ([`KeyPolicy`]): a model
/// built alone reaches every name a key spells, the whole document follows
/// esm-spec §6.6.2.
#[derive(Clone, Debug)]
enum Spelling {
    /// One model built alone, the selected or the only one: its names are
    /// model-local (`x`, a mounted `Sub.x`).
    ModelLocal(String),
    /// The whole document, flattened: every name is `Model.var`.
    Qualified,
}

impl Spelling {
    /// A resolver over `names` by this spelling's rule, a rule-2 key's
    /// leading segments checked against the namespaces of `scope`.
    fn resolver<'a>(
        &self,
        names: impl IntoIterator<Item = &'a str>,
        scope: impl IntoIterator<Item = &'a str>,
    ) -> KeyResolver {
        let policy = match self {
            Spelling::ModelLocal(m) => KeyPolicy::EveryName { model: m.clone() },
            Spelling::Qualified => KeyPolicy::Spec,
        };
        KeyResolver::new(policy, names, namespace_scope(scope, []))
    }
}

/// Every declared 0-D parameter's default (overridden by `overrides`, each key
/// read by the spelling's rule, [`Spelling::resolver`]) — the scalar evaluation scope, sorted
/// by name. A parameter with no `default` is in it only when an override
/// gives its value.
///
/// **Selection and value resolution must agree.** They did not: the filter
/// admitted every parameter with `default.is_some()`, while the value read
/// `default_scalar()`, which is `None` for inline ARRAY data
/// ([`crate::types::InlineValue::as_scalar`]) — and the `.unwrap_or(0.0)`
/// underneath then FABRICATED a zero. A 0-D parameter whose `default` is array
/// data (there is no shape for the array to fill) therefore entered the build's
/// scalar scope bound to `0.0`, and every expression reading it evaluated
/// against a number the document never states. That is a silent wrong answer,
/// which is the one outcome a build-time scope must not produce.
///
/// A parameter with array data is not a 0-D parameter's default, so it is not
/// in this scope at all. It reaches the evaluator's fail-closed path instead of
/// a plausible zero. Such a document is rejected at load as
/// `array_default_without_shape` (esm-spec §6.3); this filter stays as the
/// backstop for routes that build without structural validation, which
/// `esm_problem` does. (Its mirror image — a SCALAR default on a SHAPED parameter,
/// which must broadcast rather than be dropped — is issue #219.)
fn scalar_params(
    model: &Model,
    spelling: &Spelling,
    overrides: &HashMap<String, f64>,
) -> Result<(Vec<f64>, Vec<String>), SimulateError> {
    // Every scalar parameter: one with no `default` takes its value from an
    // override alone, and is left out without one.
    let mut names: Vec<String> = model
        .variables
        .iter()
        .filter(|(_, v)| {
            v.var_type == VariableType::Parameter
                && v.shape.as_ref().map(|s| s.is_empty()).unwrap_or(true)
        })
        .map(|(k, _)| k.clone())
        .collect();
    names.sort();
    // Each name takes the value of the key that supplies it.
    let chosen = spelling
        .resolver(
            names.iter().map(String::as_str),
            model.variables.keys().map(String::as_str),
        )
        .canonical(overrides.keys().map(String::as_str))
        .map_err(crate::simulate::param_key_error)?;
    let (vals, names): (Vec<f64>, Vec<String>) = names
        .iter()
        .filter_map(|n| {
            let v = match chosen.get(n.as_str()) {
                Some(key) => overrides[*key],
                None => model.variables[n].default_scalar()?,
            };
            Some((v, n.clone()))
        })
        .unzip();
    Ok((vals, names))
}

// --------------------------------------------------------------------------- //
// Pushdown-path name aliasing (the Python `_inject_pushdown_aliases`, adapted
// to the UN-flattened Rust model scope: the coupling routes loader keys onto
// namespaced model names, and every dotted key additionally surfaces under its
// unique shallowest bare tail — the spelling the authored expressions use).
// --------------------------------------------------------------------------- //
/// Round an array of EXTERNAL data to the working precision of the variable
/// `key` fills (`crate::precision`, esm-spec §11.3.1).
///
/// Loaded data is the one class of value the evaluator does not itself produce,
/// so under `element_type: "Float32"` it is rounded ONCE here rather than on
/// each of the O(N) reads of it; every value computed downstream is already
/// binary32 because every operation rounds. Identity under Float64.
///
/// The precision is the TARGET VARIABLE's, not the document's, because a data
/// column is exactly where a per-variable `element_type` has to bite: a
/// document-wide binary32 rounding applied to an ingested ten-digit key
/// collapses distinct codes onto one another before a single expression has
/// run (`2265007010` and `2265007015` both become `2265007104`), so a key
/// column declared `Float64` must arrive unrounded. The provider key IS the
/// variable name it fills (`esio_provider`'s `ParamBinding::key`), bare or
/// `Model.var`, which is the spelling `precision::of_variable` resolves.
///
/// Applied only to genuinely external arrays — a caller's `const_arrays`, a
/// provider sample, a gated fetch. NOT to a member-id factor (invented integer
/// ids, which binary32 would corrupt above 2^24) and not to an
/// evaluator-produced field (already binary32, so it would be a no-op sweep).
fn round_external(key: &str, mut a: ArrayD<f64>) -> ArrayD<f64> {
    let prec = crate::precision::of_variable(key);
    if prec.is_f32() {
        a.mapv_inplace(|x| prec.round(x));
    }
    a
}

fn inject_aliases(arrays: &mut ArrMap, coupling: &[(String, String)]) {
    // The coupling routing is AUTHORITATIVE: a `variable_map` explicitly binds
    // the loader field to the model variable, so surface the array under both
    // the namespaced target and its model-local tail (the authored spelling
    // the un-flattened expressions use). This also disambiguates a tail that
    // several dotted keys would otherwise tie on (`MockSR.TotalPop` vs
    // `ISRM.TotalPop`), which the generic pass below refuses to guess at.
    for (frm, to) in coupling {
        if !arrays.contains_key(frm) {
            continue;
        }
        if !arrays.contains_key(to) {
            let a = arrays[frm].clone();
            arrays.insert(to.clone(), a);
        }
        let tail = to.rsplit('.').next().unwrap_or(to);
        if !arrays.contains_key(tail) {
            let a = arrays[frm].clone();
            arrays.insert(tail.to_string(), a);
        }
    }
    // dotted key → unique shallowest bare tail (existing keys never overwritten).
    let mut tails: HashMap<String, Vec<String>> = HashMap::new();
    for k in arrays.keys() {
        if let Some((_, tail)) = k.rsplit_once('.') {
            tails.entry(tail.to_string()).or_default().push(k.clone());
        }
    }
    for (tail, mut keys) in tails {
        if arrays.contains_key(&tail) {
            continue;
        }
        let mindepth = keys
            .iter()
            .map(|k| k.matches('.').count())
            .min()
            .unwrap_or(0);
        keys.retain(|k| k.matches('.').count() == mindepth);
        keys.sort();
        if keys.len() == 1 {
            let a = arrays[&keys[0]].clone();
            arrays.insert(tail, a);
        }
    }
}

// --------------------------------------------------------------------------- //
// Build-time coordinate path (work item 2): evaluate the join-free observeds
// an overlap-gated `distinct` producer transitively reads, through the FULL
// evaluator, ahead of value-invention.
// --------------------------------------------------------------------------- //

/// The names of the join-free observeds the producer seed nodes transitively
/// reference, i.e. the build-time coordinate closure.
fn producer_seed_closure(
    seeds: &[&Expr],
    deps: &crate::dependency::DependencySummaries,
    join_free: &HashSet<String>,
) -> HashSet<String> {
    let mut needed: HashSet<String> = HashSet::new();
    let mut frontier: Vec<String> = Vec::new();
    let mut refs = HashSet::new();
    for s in seeds {
        refs.extend(crate::dependency::Reads::of(s).names);
        // A producer's `join.on` columns that are plain observeds (the
        // per-component integer bin columns of a lib/relational.esm rewrite)
        // seed the closure too, so the coordinates they read are evaluated.
        if let Expr::Operator(node) = s {
            for clause in node.join.iter().flatten() {
                refs.extend(clause.on.iter().flatten().cloned());
            }
        }
    }
    for r in refs {
        if join_free.contains(&r) && needed.insert(r.clone()) {
            frontier.push(r);
        }
    }
    while let Some(cur) = frontier.pop() {
        let Some(summary) = deps.get(&cur) else {
            continue;
        };
        for r in &summary.reads.names {
            if join_free.contains(r) && needed.insert(r.clone()) {
                frontier.push(r.clone());
            }
        }
    }
    needed
}

/// What [`eval_observed`] produced.
enum Evaluated {
    /// The dense field, and the route that evaluated it.
    Field(ArrayD<f64>, Route),
    /// Walked per cell under `refuse_per_cell`, and stopped at the first cell
    /// ([`crate::simulate_array::CellWalks`]): there is no field, only the
    /// reason to refuse.
    Refused(String),
}

/// Lower one observed on a standalone tape and run it
/// (`simulate_array::eval_observed_taped`). `None` when `recurrence_only` and
/// the observed is not a recurrence the tape's sweep takes. Otherwise the outer
/// `Err` is a fault the run latched — the interpreter's own diagnostic for the
/// same document — and the inner one the tape's decline reason.
fn compile_on_tape(
    name: &str,
    expr: &Expr,
    scope: &StandaloneScope<'_>,
    fill_shape: Option<&[usize]>,
    recurrence_only: bool,
) -> Option<Result<Result<ArrayD<f64>, String>, String>> {
    use crate::simulate_array::StandaloneError;
    let scope = StandaloneScope {
        derived_extents: crate::faq::empty_derived_extents(),
        ..*scope
    };
    match crate::simulate_array::eval_observed_taped(
        name,
        expr,
        &scope,
        fill_shape,
        recurrence_only,
    ) {
        None => None,
        Some(Ok(a)) => Some(Ok(Ok(a))),
        Some(Err(StandaloneError::Declined(why))) => Some(Ok(Err(why))),
        // Worded as the interpreter's own evaluation reports the same fault.
        Some(Err(StandaloneError::Fault(details))) => Some(Err(
            crate::compile_error::CompileError::InterpreterBuildError { details }.to_string(),
        )),
    }
}

/// The interpreter's shape for an observed's value: a scalar fills
/// `scalar_shape` ([`BuildState::scalar_shape`]), an array is kept.
fn shape_like_interpreter(a: ArrayD<f64>, scalar_shape: &[usize]) -> ArrayD<f64> {
    if a.ndim() == 0 {
        ArrayD::from_elem(IxDyn(scalar_shape), a[IxDyn(&[])])
    } else {
        a
    }
}

/// An observed's definition with every range resolved against the index sets
/// and the materialized extents: the form [`eval_observed`] evaluates.
fn resolve_observed(
    name: &str,
    def: &Expr,
    index_sets: &HashMap<String, IndexSet>,
    extents: &HashMap<String, i64>,
) -> Result<Expr, SimulateError> {
    let mut expr = def.clone();
    resolve_expr_ranges_with_extents(&mut expr, index_sets, extents)
        .map_err(|e| stage_err(format_args!("resolve ranges for {name}"), e))?;
    Ok(expr)
}

/// Evaluate one observed, its ranges already resolved ([`resolve_observed`]);
/// returns the dense field.
///
/// Under `refuse_per_cell` (a strict compiler) what the reference evaluator
/// would walk per cell goes to the tape, and a walk stops at its first cell
/// on the way, so a document the strict compiler refuses is refused for the
/// price of one cell rather than the whole reference evaluation. Otherwise
/// (the interpreter) the reference evaluator walks it.
fn eval_observed(
    name: &str,
    expr: &Expr,
    scope: &StandaloneScope<'_>,
    fill_shape: Option<&[usize]>,
    scalar_shape: &[usize],
    refuse_per_cell: bool,
) -> Result<Evaluated, SimulateError> {
    // The observed is evaluated at the element type of the variable it defines
    // (esm-spec §11.3.1) — the document's unless that variable declared its
    // own. This is where the build pipeline materializes a relational
    // document's whole observed graph, so it is where an equation over
    // binary64 keys has to be evaluated in binary64: a `sum_product` over one
    // exact key still rounds its accumulator, which is enough to turn
    // `2260007005` back into `2260006912`. A no-op swap for every document
    // that declares no per-variable element type.
    let _rule_precision = crate::precision::enter_variable(name);
    // A CAUSAL SELF-REFERENCE (esm-spec §4.3.1.1) cannot be evaluated
    // wholesale: its cells are not independent, and the self-read would
    // resolve against a map that does not yet hold the array being built.
    // Checked BEFORE the wholesale call, and returning `None` for every
    // expression that contains no self-read, so a document that does not use
    // the construct takes exactly the path it took before.
    //
    // This is the fix for the defect that made the construct dead on this
    // path: it evaluated correctly under `esm test` (the per-step observed
    // materialization) and silently wrong wherever the build pipeline was
    // taken — which is any ingesting document, and every document under
    // `esm simulate`. The self-read fell through to an unbound-name NaN and a
    // `max(x, 0)` in the body laundered it to 0.0, so the answer came back
    // finite, plausible and wrong with nothing logged.
    // Under a strict compiler a recurrence goes to the tape's ordered sweep
    // first (`compile_on_tape`), and is refused only if the tape declines it.
    if refuse_per_cell && let Some(tape) = compile_on_tape(name, expr, scope, fill_shape, true) {
        return tape
            .map_err(|why| err(format!("evaluate {name}: {why}")))
            .map(|r| match r {
                Ok(a) => Evaluated::Field(shape_like_interpreter(a, scalar_shape), Route::Tape),
                Err(declined) => Evaluated::Refused(format!(
                    "{PER_CELL_RECURRENCE}, and the tape declined it: {declined}"
                )),
            });
    }
    let mut walks = if refuse_per_cell {
        crate::simulate_array::CellWalks::stopping()
    } else {
        crate::simulate_array::CellWalks::default()
    };
    if let Some(res) = scope.eval_recurrence(name, expr, &mut walks) {
        if walks.refused() {
            return Ok(Evaluated::Refused(PER_CELL_RECURRENCE.to_string()));
        }
        return res
            .map(|a| Evaluated::Field(a, Route::PerCell(PER_CELL_RECURRENCE.to_string())))
            .map_err(|e| stage_err(format_args!("evaluate {name}"), e));
    }
    // Under a strict compiler, an observed with a `faq` the reference
    // evaluator would walk per cell is lowered whole on the tape instead,
    // from the same inputs, and refused when the tape declines it.
    use crate::simulate_array::{BuildEval, BuildRoute, Routed};
    let mode = if refuse_per_cell {
        BuildEval::Fast { strict: true }
    } else {
        BuildEval::PerCell
    };
    let routed = scope
        .eval_routed(name, expr, fill_shape, mode)
        .map_err(|e| stage_err(format_args!("evaluate {name}"), e))?;
    let (val, route) = match routed {
        Routed::Refused(declined) => {
            return Ok(Evaluated::Refused(format!(
                "a `faq` in it would be walked once per cell, and the tape declined it: \
                 {declined}"
            )));
        }
        Routed::Value(v, route) => (v, route),
    };
    let field = match val {
        EvalValue::Array(a) => *a,
        EvalValue::Scalar(s) => ArrayD::from_elem(IxDyn(scalar_shape), s),
    };
    let route = match route {
        BuildRoute::Whole => Route::Whole,
        BuildRoute::Tape => Route::Tape,
        BuildRoute::PerCell => Route::PerCell(PER_CELL_FAQ.to_string()),
    };
    Ok(Evaluated::Field(field, route))
}

// --------------------------------------------------------------------------- //
// Pushdown hook 2: the gated pre-sliced fetch.
// --------------------------------------------------------------------------- //

struct GatedFetchPlan {
    selection: Vec<AxisSel>,
    drop_axes: Vec<usize>,
    /// Position of the gated axis in the REQUEST (`selection`), i.e. before the
    /// fixed axes are dropped. This is the axis a batched fetch subdivides.
    gated_pos: usize,
    gated_pos_out: usize,
    gated_extent: usize,
    /// How many provider requests this plan will issue — filled in by the
    /// caller, which is where the batch size and `supports_selection` are known,
    /// so the whole phase can report a running count.
    n_requests: usize,
}

/// Resolve a gate's per-axis `selection` from the materialised value-invention
/// members (0-based native indices for the reader).
fn gated_fetch_plan(
    key: &str,
    gate: &ProviderGate,
    index_sets: &HashMap<String, IndexSet>,
    members: &HashMap<String, Vec<i64>>,
    extents: &HashMap<String, i64>,
) -> Result<GatedFetchPlan, SimulateError> {
    let mut selection: Vec<AxisSel> = Vec::with_capacity(gate.axes.len());
    let mut drop_axes: Vec<usize> = Vec::new();
    let mut gated_pos: Option<usize> = None;
    let mut gated_extent = 0usize;
    for (ax_i, ax) in gate.axes.iter().enumerate() {
        match ax {
            GateAxis::All => selection.push(AxisSel::All),
            GateAxis::Fixed(fi) => {
                selection.push(AxisSel::Indices(vec![*fi]));
                drop_axes.push(ax_i);
            }
            GateAxis::Range { start, stop, step } => selection.push(AxisSel::Range {
                start: *start,
                stop: *stop,
                step: *step,
            }),
            GateAxis::GatedBy(sname) => {
                let faq = index_sets
                    .get(sname)
                    .and_then(|is| (is.kind == "derived").then(|| is.from_faq.clone()))
                    .flatten()
                    .ok_or_else(|| {
                        err(format!(
                            "gated provider '{key}' gates on '{sname}' which is not a \
                             derived index set with a from_faq"
                        ))
                    })?;
                let mem = members.get(&faq).ok_or_else(|| {
                    err(format!(
                        "gated provider '{key}' gates on '{sname}' (faq '{faq}') but its \
                         value-invention members were not materialised"
                    ))
                })?;
                let mem0: Vec<usize> = mem
                    .iter()
                    .map(|&m| {
                        usize::try_from(m - 1).map_err(|_| {
                            err(format!(
                                "gated provider '{key}': member id {m} is not a 1-based \
                                 cell id"
                            ))
                        })
                    })
                    .collect::<Result<_, _>>()?;
                gated_extent = extents.get(&faq).map(|&e| e as usize).unwrap_or(mem0.len());
                selection.push(AxisSel::Indices(mem0));
                gated_pos = Some(ax_i);
            }
        }
    }
    let gated_pos = gated_pos
        .ok_or_else(|| err(format!("gated provider '{key}' declares no gated_by axis")))?;
    let gated_pos_out = gated_pos - drop_axes.iter().filter(|&&d| d < gated_pos).count();
    Ok(GatedFetchPlan {
        selection,
        drop_axes,
        gated_pos,
        gated_pos_out,
        gated_extent,
        n_requests: 1,
    })
}

/// The build pipeline's internal observation sink, erased so a helper can report
/// without knowing whether an observer is attached or what it captured.
type ReportFn<'a> =
    dyn FnMut(PreparePhase, usize, Option<usize>, &str) -> Result<(), SimulateError> + 'a;

/// Run a gate's plan, reporting through `report` and honouring a cancel.
///
/// One request, unless `batch` splits the gated axis' index list into contiguous
/// runs — in which case the pieces are assembled into ONE pre-allocated slab in
/// request order, which is bit-identical to the single-request result because
/// nothing is reordered and the concatenation seam is a plain copy. Assembling
/// in place rather than via `ndarray::concatenate` matters at this size: the SR
/// slabs are hundreds of MB, and holding every piece plus their concatenation
/// would peak at twice the answer instead of the answer plus one batch.
#[allow(clippy::too_many_arguments)]
fn run_gated_fetch(
    key: &str,
    prov: &mut dyn DataProvider,
    plan: &GatedFetchPlan,
    batch: Option<usize>,
    issued: &mut usize,
    total_requests: usize,
    report: &mut ReportFn<'_>,
) -> Result<ArrayD<f64>, SimulateError> {
    // A provider that cannot push the selection down fetches the WHOLE field in
    // one indivisible call and is sliced engine-side; there is no seam to batch
    // and reporting per batch would be a lie about work already done.
    if !prov.supports_selection() {
        report(PreparePhase::GatedFetch, *issued, Some(total_requests), key)?;
        *issued += 1;
        let full = prov
            .sample()
            .map_err(|e| err(format!("gated fetch '{key}' (whole): {}", e.0)))?;
        return drop_fixed_axes(key, slice_whole(full, &plan.selection), &plan.drop_axes);
    }

    let AxisSel::Indices(gated_idx) = &plan.selection[plan.gated_pos] else {
        return Err(err(format!(
            "gated provider '{key}': the gated axis resolved to the full axis, \
             which is not a support set"
        )));
    };
    let size = batch.unwrap_or(usize::MAX).max(1);
    let n_batches = gated_idx.len().div_ceil(size).max(1);

    if n_batches == 1 {
        report(PreparePhase::GatedFetch, *issued, Some(total_requests), key)?;
        *issued += 1;
        let a = prov
            .sample_with_selection(&plan.selection)
            .map_err(|e| err(format!("gated fetch '{key}': {}", e.0)))?;
        return drop_fixed_axes(key, a, &plan.drop_axes);
    }

    let mut out: Option<ArrayD<f64>> = None;
    let mut filled = 0usize;
    for (i, run) in gated_idx.chunks(size).enumerate() {
        // BEFORE the request: a cancel here skips the fetch rather than
        // arriving just after it, which is the entire point of subdividing.
        report(PreparePhase::GatedFetch, *issued, Some(total_requests), key)?;
        *issued += 1;
        let mut sel = plan.selection.clone();
        sel[plan.gated_pos] = AxisSel::Indices(run.to_vec());
        let part = prov
            .sample_with_selection(&sel)
            .map_err(|e| err(format!("gated fetch '{key}' (batch {i}): {}", e.0)))?;
        let part = drop_fixed_axes(key, part, &plan.drop_axes)?;
        let width = part.shape().get(plan.gated_pos_out).copied().unwrap_or(0);
        if width != run.len() {
            return Err(err(format!(
                "gated provider '{key}': batch {i} asked for {} indices and got \
                 {width} back",
                run.len()
            )));
        }
        let dst = out.get_or_insert_with(|| {
            let mut shape = part.shape().to_vec();
            shape[plan.gated_pos_out] = gated_idx.len();
            ArrayD::zeros(IxDyn(&shape))
        });
        dst.slice_axis_mut(
            Axis(plan.gated_pos_out),
            Slice::from(filled..filled + width),
        )
        .assign(&part);
        filled += width;
    }
    out.ok_or_else(|| err(format!("gated provider '{key}': no batches were fetched")))
}

/// Drop the (length-1) fixed axes of a fetched slab.
fn drop_fixed_axes(
    key: &str,
    arr: ArrayD<f64>,
    drop_axes: &[usize],
) -> Result<ArrayD<f64>, SimulateError> {
    if drop_axes.is_empty() {
        return Ok(arr);
    }
    let shape = arr.shape().to_vec();
    for &d in drop_axes {
        if shape.get(d).copied() != Some(1) {
            return Err(err(format!(
                "gated provider '{key}': fixed axis {d} came back with length \
                 {:?} (expected 1) in shape {shape:?}",
                shape.get(d)
            )));
        }
    }
    let out: Vec<usize> = shape
        .iter()
        .enumerate()
        .filter(|(i, _)| !drop_axes.contains(i))
        .map(|(_, &s)| s)
        .collect();
    arr.into_shape_with_order(IxDyn(&out)).map_err(|e| {
        err(format!(
            "gated provider '{key}': reshape after fixed-axis drop: {e}"
        ))
    })
}

/// FALLBACK slice for a provider that cannot push a selection down: fetch
/// whole, then take the selected indices axis by axis (identical result).
pub(crate) fn slice_whole(full: ArrayD<f64>, selection: &[AxisSel]) -> ArrayD<f64> {
    let mut arr = full;
    for (i, ax) in selection.iter().enumerate() {
        if matches!(ax, AxisSel::All) {
            continue;
        }
        let dim_len = arr.shape().get(i).copied().unwrap_or(0);
        let idx = ax.indices(dim_len);
        arr = arr.select(Axis(i), &idx);
    }
    arr
}

// --------------------------------------------------------------------------- //
// The entry point.
// --------------------------------------------------------------------------- //

/// Does `raw` carry an esm-spec §9.7.2 import EDGE — at the top level of a
/// library file, or inside a component?
///
/// The pushdown prepass reads the RAW document, before the typed load, so an
/// edge that is still unresolved hides the imported templates and index sets
/// from the recogniser: the binning body reads as an unexpandable
/// `apply_expression_template` and the rewrite silently declines, which costs
/// the whole ungated fetch. Resolving is gated on this predicate rather than run
/// unconditionally so a document with no edge reaches `desugar_pushdown` in
/// exactly the bytes it does today (metaparameters unfolded, goldens unmoved).
fn has_template_import_edge(raw: &JsonValue) -> bool {
    let Some(obj) = raw.as_object() else {
        return false;
    };
    // Either spelling: the old one is read as the new at load (esm-spec
    // §9.6.12).
    let edge = |o: &serde_json::Map<String, JsonValue>| {
        o.contains_key("operator_imports") || o.contains_key("expression_template_imports")
    };
    if edge(obj) {
        return true;
    }
    ["models", "reaction_systems"].iter().any(|kind| {
        obj.get(*kind)
            .and_then(JsonValue::as_object)
            .is_some_and(|comps| comps.values().any(|c| c.as_object().is_some_and(edge)))
    })
}

/// Run the deterministic-per-document pipeline over `doc` (a raw parsed `.esm`
/// document), once: pushdown rewrite (when opted in) → loader extent discovery
/// → typed load → provider materialization → build-time coordinate evaluation
/// → value invention → member-factor feedback → gated pre-sliced fetch →
/// dependency-ordered observed-graph evaluation. Returns the [`PreparedBuild`]
/// artifact.
///
/// `providers` maps the CONSUMING PARAMETER's namespaced name
/// (`"<ModelPath>.<param>"`) to a CONST [`DataProvider`]; an entry the
/// rewrite record's gate routes onto a gated array is DEFERRED and fetched
/// pre-sliced after value-invention. From esm 1.0.0 a data source declares no
/// variables, so the consuming parameter is the only spelling that names one
/// field and every field: two parameters may read one `file_variable`
/// differently, and two models may declare the same parameter name against one
/// source. `const_arrays` are the caller-supplied build-time factor arrays
/// (keyed by model-local or `<Source>.<file_variable>` names — the routing
/// aliasing surfaces both spellings).
///
/// Crate-internal: the public entry point is
/// [`crate::problem::esm_problem`], which calls this and then compiles the
/// right-hand side.
///
/// # Watching a long build
///
/// A build over real data is not fast: on the InMAP ISRM the gated fetch alone
/// is tens of gigabytes and the whole `prepare` runs for the better part of a
/// quarter of an hour. [`crate::problem::ProblemOptions::progress`] observes it as it goes —
/// per gated request and per observed, not merely per phase — and returning
/// [`Flow::Cancel`] stops it at a named point. Pair it with
/// [`crate::problem::ProblemOptions::gated_fetch_batch`] so the fetch itself is interruptible.
///
/// `timed` holds the TIME-VARYING providers (those with refresh times). What
/// the build does with them depends on whether the built model has state:
///
/// * with nothing to integrate, the build's fields ARE the document's
///   answer, materialized once at `t0`, so each one is consumed here as the
///   record in effect at `t0` ([`InEffectAt`]), exactly as a CONST provider
///   is: gated by its own gate or the pushdown rewrite's, and sampled whole
///   by extent discovery. The parameters they feed and every observed that
///   reads one are recorded ([`crate::problem::BuildProducts::time_pinned`])
///   so that nothing answers from these fields at another time;
/// * with state, they are left in `timed` for the run-time executor, and an
///   observed reading a parameter one of them feeds, directly or through
///   another observed, is not evaluated at build time: its value moves at
///   every refresh, so it is evaluated at run time, as an observed reading a
///   state is.
///
/// Either way an observed reading such a parameter — a record-shaped one
/// (esm-spec §8.5.1) included — is never evaluated against a scope that does
/// not hold it. Whether the model has state is known only after the typed
/// load, which needs the extents discovery closes, so discovery reads every
/// provider's extent, time-varying ones included (a record's leading axis is
/// the same in every record), and the rewrite's gates for the time-varying
/// providers are read after the load.
pub(crate) fn run_prepare(
    doc: &JsonValue,
    const_arrays: HashMap<String, ArrayD<f64>>,
    providers: Vec<(String, Box<dyn DataProvider>)>,
    timed: &mut Vec<(String, Box<dyn DataProvider>)>,
    opts: &BuildContext<'_>,
) -> Result<PreparedBuild, SimulateError> {
    let mut providers = providers;
    let mut metaparameters = opts.problem.metaparameters.clone();
    let n_const = providers.len();
    providers.append(timed);
    let discovered = discover_loader_extents(&mut providers, opts, &mut metaparameters);
    *timed = providers.split_off(n_const);
    let mut discovered = discovered?;
    let timed_keys: Vec<String> = timed.iter().map(|(k, _)| k.clone()).collect();

    let resolved = resolve_pushdown_imports(doc, opts, &metaparameters)?;
    let doc: &JsonValue = resolved.as_ref().unwrap_or(doc);
    let provider_keys: Vec<String> = providers.iter().map(|(k, _)| k.clone()).collect();
    let mut rw = apply_pushdown_rewrite(doc, opts, &provider_keys)?;
    check_discovered_gate_conflict(&discovered, &rw.pd_gates)?;

    let mut st = BuildState::load_document(rw.rewritten.as_ref(), opts, metaparameters)?;
    if st.has_state() {
        st.runtime_fed = st.parameters_fed_by(timed_keys.iter().map(String::as_str));
    } else if !timed.is_empty() {
        if matches!(rw.rewritten, std::borrow::Cow::Owned(_)) {
            let gates =
                pushdown_provider_gates(&rw.rewritten, &timed_keys).map_err(|e| err(e.0))?;
            rw.pd_gates.extend(gates);
            check_discovered_gate_conflict(&discovered, &rw.pd_gates)?;
        }
        st.time_pinned = st.parameters_fed_by(timed_keys.iter().map(String::as_str));
        let t0 = opts.t0;
        for (k, p) in timed.drain(..) {
            let feeds = st.fed_parameter(&k);
            let fallback = feeds.as_deref().and_then(|n| st.declared_default_field(n));
            let wrapped = InEffectAt {
                inner: p,
                t: t0,
                feeds: feeds.unwrap_or_else(|| k.clone()),
                fallback,
                delivered: None,
            };
            providers.push((k, Box::new(wrapped)));
        }
    }
    // A time-varying provider's discovery read only its extent, from its
    // time-less sample; its value is the record in effect at `t0`, read below.
    for k in &timed_keys {
        discovered.remove(k);
    }
    let gated = st.inject_providers(const_arrays, providers, discovered, &rw.pd_gates)?;
    st.alias_pushdown_names(&rw.pd_coupling);
    st.bind_inline_parameters(&gated, &rw.pd_coupling)?;
    st.seal_const_registry();
    st.check_free_names()?;
    st.collect_observed_defs()?;
    st.eval_buildtime_coordinates()?;
    if st.refused.is_some() {
        return Ok(st.finish(rw.rewritten.into_owned()));
    }
    st.invent_values()?;
    st.feed_member_factors()?;
    st.prune_to_observed_cone();
    st.eval_observeds_before_fetch(&gated, &rw.pd_coupling)?;
    if st.refused.is_some() {
        return Ok(st.finish(rw.rewritten.into_owned()));
    }
    st.fetch_gated_providers(gated, &rw.pd_coupling)?;
    st.eval_observed_graph()?;
    Ok(st.finish(rw.rewritten.into_owned()))
}

/// A TIME-VARYING provider as the CONST provider of the record in effect at
/// `t`: the latest record whose time is at or before `t` (esm-spec §8.5.1, a
/// record-shaped parameter's pair included). [`run_prepare`] wraps each one
/// this way for a document with nothing to integrate, whose fields the build
/// materializes once, at `t`.
///
/// With no record in effect at `t` (every refresh time is later), the
/// parameter `feeds` takes its declared default (`fallback`), as it does at a
/// solve's start (esm-spec §11.4.2 item 5); one that declares none is refused.
struct InEffectAt {
    inner: Box<dyn DataProvider>,
    t: f64,
    /// The parameter this provider feeds (its key when it designates none),
    /// for the refusal.
    feeds: String,
    /// The declared default of [`Self::feeds`] over its declared shape.
    fallback: Option<ArrayD<f64>>,
    /// The record this provider delivered: every later sample is it again.
    delivered: Option<ArrayD<f64>>,
}

impl InEffectAt {
    fn in_effect(&mut self) -> Result<ArrayD<f64>, crate::provider::ProviderError> {
        // A provider answers `refresh` at any time, `None` when it has nothing
        // new there; it then still holds the record of its latest refresh time
        // before `t`, which is asked for directly.
        if let Some(a) = self.inner.refresh(self.t)? {
            return Ok(a);
        }
        let before = self
            .inner
            .refresh_times()
            .into_iter()
            .filter(|&b| b <= self.t)
            .max_by(f64::total_cmp);
        match before {
            Some(b) => match self.inner.refresh(b)? {
                Some(a) => Ok(a),
                None => self.inner.sample(),
            },
            None => self.fallback.clone().ok_or_else(|| {
                crate::error::MessageError(format!(
                    "the provider has no record in effect at time_span.start {} (it \
                     delivered nothing there, nor at a refresh time before it), and the \
                     parameter `{}` it feeds declares no default",
                    self.t, self.feeds
                ))
            }),
        }
    }
}

impl DataProvider for InEffectAt {
    fn sample(&mut self) -> Result<ArrayD<f64>, crate::provider::ProviderError> {
        if let Some(a) = &self.delivered {
            return Ok(a.clone());
        }
        let a = self.in_effect()?;
        self.delivered = Some(a.clone());
        Ok(a)
    }

    /// A selection on the inner provider would read its time-less record,
    /// not the one in effect at `t`, so none is pushed down: a gated fetch
    /// samples the record in effect whole and slices it.
    fn supports_selection(&self) -> bool {
        false
    }

    fn sample_with_selection(
        &mut self,
        selection: &[crate::provider::AxisSel],
    ) -> Result<ArrayD<f64>, crate::provider::ProviderError> {
        Ok(slice_whole(self.sample()?, selection))
    }

    fn gate_spec(&self) -> Option<ProviderGate> {
        self.inner.gate_spec()
    }

    fn extent_metaparameter(&self) -> Option<String> {
        self.inner.extent_metaparameter()
    }
}

/// Verbose-mode narration; a no-op unless [`crate::problem::ProblemOptions::verbose`] is set.
fn vlog(opts: &BuildContext<'_>, msg: &str) {
    if opts.problem.verbose {
        println!("{msg}");
    }
}

/// The observation point. Every phase boundary and every countable unit of
/// work inside the two phases that dominate a large build goes through here,
/// so the phase structure `verbose` narrates and the phase structure a host
/// observes cannot drift — there is only one.
///
/// Returns `Err` on `Flow::Cancel`, which unwinds `prepare` through the `?`
/// it is already threaded on. The message names the phase and the item, so a
/// cancel is attributable to a point in the build rather than to a wall
/// clock the library does not have.
fn report_progress(
    opts: &BuildContext<'_>,
    phase: PreparePhase,
    done: usize,
    total: Option<usize>,
    item: &str,
) -> Result<(), SimulateError> {
    let Some(cb) = &opts.problem.progress else {
        return Ok(());
    };
    let p = PrepareProgress {
        phase,
        done,
        total,
        item,
    };
    match cb(&p) {
        Flow::Continue => Ok(()),
        Flow::Cancel => Err(SimulateError::Cancelled {
            details: format!(
                "{phase}{}",
                if item.is_empty() {
                    match total {
                        Some(t) => format!(" ({done} of {t} done)"),
                        None => String::new(),
                    }
                } else {
                    match total {
                        Some(t) => format!(" at '{item}' ({} of {t})", done + 1),
                        None => format!(" at '{item}'"),
                    }
                }
            ),
        }),
    }
}

/// Extent discovery: a loader that measures its OWN record count.
///
/// FIRST, ahead of the rewrite, because a discovered extent binds a
/// metaparameter and every resolution below closes metaparameters at the
/// loader API (§9.7.6 site 4). This is the Julia ordering (`simulate.jl`
/// prepare); Rust used to discover AFTER the rewrite, which was harmless only
/// for as long as nothing between the two steps folded a metaparameter — the
/// §9.7 resolution below does. A gated provider is still rejected outright:
/// its extent is the value-invention set's, which does not exist yet — the
/// provider's OWN declared gate is caught here, the gate the rewrite record
/// derives in the check after the rewrite.
fn discover_loader_extents(
    providers: &mut [(String, Box<dyn DataProvider>)],
    opts: &BuildContext<'_>,
    metaparameters: &mut BTreeMap<String, i64>,
) -> Result<HashMap<String, ArrayD<f64>>, SimulateError> {
    let mut discovered: HashMap<String, ArrayD<f64>> = HashMap::new();
    let mut discovered_by: BTreeMap<String, (i64, String)> = BTreeMap::new();
    for (key, prov) in providers.iter_mut() {
        let Some(mp) = prov.extent_metaparameter() else {
            continue;
        };
        if prov.gate_spec().is_some() {
            return Err(err(format!(
                "provider '{key}' both GATES on a derived index set and declares the \
                 extent metaparameter '{mp}'; a gated slab's extent is the gating \
                 set's, not a discovered one"
            )));
        }
        let a = prov
            .sample()
            .map_err(|e| err(format!("extent discovery for '{key}': {}", e.0)))?;
        let n = a.shape().first().copied().unwrap_or(0) as i64;
        if let Some((prev, prev_key)) = discovered_by.get(&mp)
            && *prev != n
        {
            return Err(err(format!(
                "loader extent '{mp}' is {prev} from provider '{prev_key}' but {n} from \
                 '{key}' — the loader's variables are not aligned on one record axis"
            )));
        }
        if let Some(bound) = metaparameters.get(&mp)
            && *bound != n
            && !discovered_by.contains_key(&mp)
        {
            return Err(err(format!(
                "metaparameter '{mp}' was closed at {bound} by the caller but provider \
                 '{key}' discovers {n} records; drop the binding and let the loader \
                 declare its own extent"
            )));
        }
        vlog(opts, &format!("  [prepare] extent {mp} <- {key} = {n}"));
        discovered_by.insert(mp.clone(), (n, key.clone()));
        metaparameters.insert(mp, n);
        discovered.insert(key.clone(), a);
    }
    Ok(discovered)
}

/// Phase-1 semantics: pushdown prepass BEFORE the typed parse.
///
/// §9.7 imports resolve BEFORE the recogniser looks. `desugar_pushdown`
/// expands `apply_expression_template` references to find the containment
/// predicate, but it can only expand what is IN SCOPE — and an import edge
/// puts the library's templates and index sets in scope at LOAD, which has
/// not happened yet on this raw-JSON path. Skipping this makes a document
/// that factors its binning body through an imported library fail detection
/// silently and fetch every provider-backed array whole.
fn resolve_pushdown_imports(
    doc: &JsonValue,
    opts: &BuildContext<'_>,
    metaparameters: &BTreeMap<String, i64>,
) -> Result<Option<JsonValue>, SimulateError> {
    report_progress(opts, PreparePhase::Rewrite, 0, None, "")?;
    if opts.problem.pushdown_rewrite && has_template_import_edge(doc) {
        resolve_template_machinery(
            doc,
            opts.problem
                .base_path
                .clone()
                .unwrap_or_else(|| PathBuf::from("."))
                .as_path(),
            metaparameters,
        )
        .map_err(|e| err(format!("resolve template imports: {}", e.message)))
    } else {
        Ok(None)
    }
}

/// What the pushdown rewrite phase hands the rest of the pipeline.
struct RewriteOutcome<'a> {
    /// The document the typed load parses: the rewrite's output when it fired,
    /// the input borrowed unchanged otherwise.
    rewritten: std::borrow::Cow<'a, JsonValue>,
    /// Record-derived provider gates (the rewrite's own `metadata.x_esd.pushdown`).
    pd_gates: HashMap<String, ProviderGate>,
    /// The pushdown coupling routing (loader key → namespaced model name).
    pd_coupling: Vec<(String, String)>,
}

/// Run the pushdown rewrite (when opted in) and read its gate and coupling
/// metadata off the rewritten document.
fn apply_pushdown_rewrite<'a>(
    doc: &'a JsonValue,
    opts: &BuildContext<'_>,
    provider_keys: &[String],
) -> Result<RewriteOutcome<'a>, SimulateError> {
    let rewritten = if opts.problem.pushdown_rewrite {
        desugar_pushdown_for_build(doc, opts.problem.model_name.as_deref())?
    } else {
        std::borrow::Cow::Borrowed(doc)
    };
    let rewrite_fired = matches!(rewritten, std::borrow::Cow::Owned(_));
    let pd_gates: HashMap<String, ProviderGate> = if rewrite_fired {
        pushdown_provider_gates(&rewritten, provider_keys).map_err(|e| err(e.0))?
    } else {
        HashMap::new()
    };
    let pd_coupling = pushdown_coupling_pairs(&rewritten);
    vlog(
        opts,
        &format!(
            "  [prepare] pushdown rewrite {}",
            if rewrite_fired {
                "fired"
            } else {
                "did not fire"
            }
        ),
    );
    Ok(RewriteOutcome {
        rewritten,
        pd_gates,
        pd_coupling,
    })
}

/// The pushdown rewrite of the model(s) this build builds.
///
/// One model, selected or the only one, is rewritten as [`desugar_pushdown`]
/// rewrites it. A document of several models with none selected is built
/// whole, so every model is offered to the rewrite: the one model whose
/// pattern matches is rewritten in the document. The rewrite records ONE
/// gate per document (`metadata.x_esd.pushdown`), so a document in which it
/// matches several models is refused, naming them, rather than rewritten in
/// one and silently left unrewritten in the rest.
fn desugar_pushdown_for_build<'a>(
    doc: &'a JsonValue,
    model_name: Option<&str>,
) -> Result<std::borrow::Cow<'a, JsonValue>, SimulateError> {
    let models: Vec<&String> = match (model_name, doc.get("models").and_then(|m| m.as_object())) {
        (None, Some(models)) if models.len() > 1 => {
            let mut names: Vec<&String> = models.keys().collect();
            names.sort();
            names
        }
        _ => return desugar_pushdown(doc, model_name).map_err(|e| err(e.0)),
    };
    let mut fired: Vec<(&str, JsonValue)> = Vec::new();
    for m in models {
        if let std::borrow::Cow::Owned(d) = desugar_pushdown(doc, Some(m)).map_err(|e| err(e.0))? {
            fired.push((m.as_str(), d));
        }
    }
    match fired.len() {
        0 => Ok(std::borrow::Cow::Borrowed(doc)),
        1 => Ok(std::borrow::Cow::Owned(fired.pop().expect("one").1)),
        _ => {
            let names: Vec<&str> = fired.iter().map(|(m, _)| *m).collect();
            Err(err(format!(
                "the projection-pushdown rewrite matches models {}; a document records \
                 one pushdown gate, so build each of them on its own (pass model_name)",
                names.join(", ")
            )))
        }
    }
}

/// A discovered extent and a record-derived gate are mutually exclusive: a
/// gated slab's extent belongs to the gating set, which value-invention has
/// not materialised yet. (The provider's OWN declared gate is caught in the
/// discovery loop above; this catches the gate the rewrite record derives,
/// which only exists now.)
fn check_discovered_gate_conflict(
    discovered: &HashMap<String, ArrayD<f64>>,
    pd_gates: &HashMap<String, ProviderGate>,
) -> Result<(), SimulateError> {
    for key in discovered.keys() {
        if pd_gates.contains_key(key) {
            return Err(err(format!(
                "provider '{key}' both GATES on a derived index set and declares an \
                 extent metaparameter; a gated slab's extent is the gating set's, not \
                 a discovered one"
            )));
        }
    }
    Ok(())
}

/// The build pipeline's accumulator state: the evaluation namespace plus the
/// artifacts each phase deposits for the phases after it. One method per
/// phase; [`run_prepare`] is the phase list.
struct BuildState<'o> {
    opts: &'o BuildContext<'o>,
    /// The typed model under build: the selected (or only) model, or the
    /// whole document's flattened system.
    model: Model,
    /// How the built model's names are spelled: model-local for one model,
    /// `Model.var` for the whole document (see [`PreparedBuild::model_name`]).
    spelling: Spelling,
    /// The built model's variable names, and the spelling's rule for
    /// mapping a caller key onto them.
    keys: KeyResolver,
    /// See [`PreparedBuild::file`].
    file: crate::EsmFile,
    /// See [`PreparedBuild::flattened`].
    flattened: Option<crate::flatten::FlattenedSystem>,
    index_sets: HashMap<String, IndexSet>,
    /// The scalar evaluation scope (declared 0-D parameter defaults, overridden).
    param_vals: Vec<f64>,
    param_names: Vec<String>,
    /// The evaluation namespace: the build-time factor data, then everything
    /// the pipeline materialises into it (gated slabs, member factors,
    /// evaluated observeds).
    arrays: ArrMap,
    /// The CONST-ARRAY registry (see [`BuildState::seal_const_registry`]).
    const_scope: ConstArrayScope,
    /// The operator registry the model's references resolve against.
    operators: crate::operator_refs::OperatorRegistry,
    /// Its instances, each body resolved as an observed definition is
    /// ([`BuildState::collect_observed_defs`]).
    ops: std::sync::Arc<crate::operator_refs::Instances>,
    /// Observed definitions, their dependency summaries, their join-free
    /// partition, and dependency order.
    defs: HashMap<String, Expr>,
    deps: crate::dependency::DependencySummaries,
    join_free: HashSet<String>,
    order: Vec<String>,
    /// Evaluated observed fields — the [`PreparedBuild::fields`] payload.
    fields: HashMap<String, ArrayD<f64>>,
    /// Value-invention products.
    members: HashMap<String, Vec<i64>>,
    extents: HashMap<String, i64>,
    /// The gated providers' keys, sorted — [`PreparedBuild::gated_provider_keys`].
    gated_keys: Vec<String>,
    /// [`PreparedBuild::rules`] / [`PreparedBuild::refused`].
    rules: Vec<PipelineRule>,
    refused: Option<PipelineRule>,
    /// The observeds evaluated ahead of the gated fetch (see
    /// [`BuildState::eval_observeds_before_fetch`]), and the progress
    /// counters the observed phase shares across its two passes.
    evaluated: HashSet<String>,
    obs_done: usize,
    obs_total: usize,
    /// [`PreparedBuild::observed_cone_applied`].
    cone_applied: bool,
    /// [`PreparedBuild::built_variables`]: the build's shape table, which
    /// also names the unshaped observeds whose shape the data of their
    /// unshaped data-fed parameters decides (esm-spec §4.3.4,
    /// [`crate::simulate_array::ShapeTable::data_shaped`]).
    built_variables: BuiltVariables,
    /// The data-fed parameters a TIME-VARYING provider feeds at run time
    /// (see [`run_prepare`]): an observed reading one is evaluated at run
    /// time, not here.
    runtime_fed: HashSet<String>,
    /// The data-fed parameters a TIME-VARYING provider fed with its record
    /// in effect at `t0`, in a build with nothing to integrate (see
    /// [`run_prepare`]).
    time_pinned: HashSet<String>,
}

impl<'o> BuildState<'o> {
    /// Whether the built model has state: an unknown that is not an observed
    /// (an ODE state or an algebraic unknown solved for).
    fn has_state(&self) -> bool {
        let class = crate::classification::Classification::of(&self.model);
        self.model
            .variables
            .iter()
            .any(|(name, var)| var.var_type == VariableType::Unknown && !class.is_observed(name))
    }

    /// The data-fed parameters of the built model a provider under one of
    /// `keys` feeds, each key resolved to at most one ([`Self::fed_parameter`]).
    fn parameters_fed_by<'k>(&self, keys: impl Iterator<Item = &'k str>) -> HashSet<String> {
        keys.filter_map(|k| self.fed_parameter(k)).collect()
    }

    /// The one data-fed parameter of the built model a provider keyed `key`
    /// feeds, by the key rules its data is routed by (esm-spec §6.6.2): in
    /// the whole-document build the `Model.var` the key designates
    /// ([`Self::array_routes`]); model-locally the name it spells most
    /// strongly, a key prefixed by the built model's name before a bare
    /// suffix. `None` when it designates no data-fed parameter, or several
    /// equally.
    fn fed_parameter(&self, key: &str) -> Option<String> {
        let name = match self.spelling {
            Spelling::Qualified => {
                let mut hits = self.keys.designates(key).ok()?;
                (hits.len() == 1).then(|| hits.remove(0).0)?
            }
            Spelling::ModelLocal(_) => self.keys.strongest(key).ok()??,
        };
        let var = self.model.variables.get(&name)?;
        (var.var_type == VariableType::Parameter
            && var
                .update
                .as_ref()
                .is_some_and(crate::data_fed::is_data_fed))
        .then_some(name)
    }

    /// The declared default of the parameter `name` over its declared shape
    /// (a scalar broadcast, or its inline array data; esm-spec §6.3), or
    /// `None` when it declares none or its shape does not resolve here.
    fn declared_default_field(&self, name: &str) -> Option<ArrayD<f64>> {
        let var = self.model.variables.get(name)?;
        let default = var.default.as_ref()?;
        let shape: Vec<usize> = match var.shape.as_deref() {
            None => Vec::new(),
            Some(decl) => crate::simulate_array::resolve_declared_shape(decl, &self.index_sets)?,
        };
        if let Some(v) = default.as_scalar() {
            return Some(ArrayD::from_elem(IxDyn(&shape), v));
        }
        let (dense_shape, values) = default.to_dense().ok()?;
        (dense_shape == shape)
            .then(|| ArrayD::from_shape_vec(IxDyn(&shape), values).ok())
            .flatten()
    }

    /// The shape `name`'s value fills when its body evaluates to a single
    /// number, decided before it is evaluated (esm-spec §4.3.4: a binding
    /// MUST NOT let the value's rank replace the declared shape): its declared
    /// shape — the build's, for an unshaped mixed-rank `ifelse` — or, for one
    /// whose shape the data of its data-fed parameters decides, the shape that
    /// data has here. `None` when neither gives one the registry can size.
    /// Both come from the build's shape table; an inferred shape is not a
    /// declared one, as rule lowering reads it.
    fn fill_shape(&self, name: &str) -> Option<Vec<usize>> {
        let shapes = &self.built_variables.shapes;
        shapes
            .declared(name)
            .filter(|s| !s.is_empty())
            .and_then(|s| crate::simulate_array::resolve_declared_shape(s, &self.index_sets))
            .or_else(|| {
                let fed = shapes.data_shaped(name)?;
                crate::flatten::data_fill_shape(fed, |n| {
                    self.arrays.get(n).map(|a| a.shape().to_vec())
                })
            })
    }

    /// [`Self::fill_shape`], else the [`DeclaredRank`] shape.
    fn scalar_shape(&self, name: &str) -> Vec<usize> {
        self.fill_shape(name)
            .unwrap_or_else(|| DeclaredRank::of(&self.model, name).scalar_shape().to_vec())
    }

    fn log(&self, msg: &str) {
        vlog(self.opts, msg);
    }

    /// The evaluation scope an observed is evaluated in: the namespace, the
    /// scalar parameters, and `t` at the start of the time span, as the
    /// static route evaluates it.
    fn scope<'s>(&'s self, extents: &'s HashMap<String, i64>) -> StandaloneScope<'s> {
        StandaloneScope {
            inputs: &self.arrays,
            params: &self.param_vals,
            param_names: &self.param_names,
            t: self.opts.t0,
            derived_extents: extents,
            const_arrays: &self.const_scope,
            ops: &self.ops,
        }
    }

    fn report(
        &self,
        phase: PreparePhase,
        done: usize,
        total: Option<usize>,
        item: &str,
    ) -> Result<(), SimulateError> {
        report_progress(self.opts, phase, done, total, item)
    }

    /// Typed load (metaparameters closed at the loader API).
    fn load_document(
        rewritten: &JsonValue,
        opts: &'o BuildContext<'o>,
        metaparameters: BTreeMap<String, i64>,
    ) -> Result<Self, SimulateError> {
        report_progress(opts, PreparePhase::Load, 0, None, "")?;
        let text = serde_json::to_string(rewritten)
            .map_err(|e| err(format!("serialize rewritten document: {e}")))?;
        // A loader-API binding names something in the AUTHORED document. By the
        // time this runs, the document may already have been inlined by an
        // earlier load — a §4.7 mount CONSUMES the leaf's `metaparameters`
        // (§9.7.6 site 3), so a name only the leaf declared is no longer
        // declared anywhere and the `{ref}` stub the mount walk reads is gone.
        // Re-binding it here would be refused as an unknown name, on a document
        // whose axes that very binding already folded. Keep only what this
        // document can still act on: a name it declares itself, or any name at
        // all while it still carries an unresolved mount for the walk to find.
        let metaparameters = if document_has_unresolved_mount(rewritten) {
            metaparameters
        } else {
            let declared = rewritten.get("metaparameters").and_then(|v| v.as_object());
            metaparameters
                .into_iter()
                .filter(|(k, _)| declared.is_some_and(|d| d.contains_key(k)))
                .collect()
        };
        let load_opts = LoadOptions {
            base_path: opts.problem.base_path.clone(),
            metaparameters,
        };
        let mut file = crate::parse::load_string_with_options(&text, &load_opts)
            .map_err(|e| err(format!("load rewritten document: {e}")))?;
        let index_sets: HashMap<String, IndexSet> = file
            .index_sets
            .clone()
            .unwrap_or_default()
            .into_iter()
            .collect();
        let models = file
            .models
            .as_ref()
            .ok_or_else(|| err("document has no models"))?;
        let spelling = match &opts.problem.model_name {
            Some(n) => Spelling::ModelLocal(n.clone()),
            None if models.len() == 1 => {
                Spelling::ModelLocal(models.keys().next().cloned().unwrap_or_default())
            }
            None => Spelling::Qualified,
        };
        let (normalized, flattened, bound_inputs) = match &spelling {
            Spelling::ModelLocal(n) => {
                let (normalized, flat) = Self::model_alone(&mut file, n, index_sets)?;
                (
                    normalized,
                    builds_alone_as_itself(&file).then_some(flat),
                    None,
                )
            }
            Spelling::Qualified => {
                let (flat, index_sets) = Self::whole_document(&file, index_sets)?;
                crate::compile_error::refuse_reserved_lifting(&flat)
                    .map_err(SimulateError::Compile)?;
                let normalized = crate::simulate_array::normalize(
                    BuildInput::Flattened {
                        flat: &flat,
                        inherited: None,
                        init: None,
                    },
                    index_sets,
                )
                .map_err(SimulateError::Compile)?;
                let bound = flat.metadata.bound_inputs.clone();
                (normalized, Some(flat), Some(bound))
            }
        };
        let NormalizedModel {
            model,
            index_sets,
            shapes,
            operators,
        } = normalized;
        let built_variables = BuiltVariables {
            shapes: std::sync::Arc::new(shapes),
            bound_inputs: bound_inputs.unwrap_or_default(),
        };

        let (param_vals, param_names) = scalar_params(&model, &spelling, &opts.problem.p)?;
        let keys = spelling.resolver(
            model.variables.keys().map(String::as_str),
            model.variables.keys().map(String::as_str),
        );

        Ok(BuildState {
            opts,
            model,
            spelling,
            keys,
            file,
            flattened,
            index_sets,
            param_vals,
            param_names,
            arrays: ArrMap::default(),
            const_scope: ConstArrayScope::default(),
            operators,
            ops: Default::default(),
            defs: HashMap::new(),
            deps: Default::default(),
            join_free: HashSet::new(),
            order: Vec::new(),
            fields: HashMap::new(),
            members: HashMap::new(),
            extents: HashMap::new(),
            gated_keys: Vec::new(),
            rules: Vec::new(),
            refused: None,
            evaluated: HashSet::new(),
            obs_done: 0,
            obs_total: 0,
            cone_applied: false,
            built_variables,
            runtime_fed: HashSet::new(),
            time_pinned: HashSet::new(),
        })
    }

    /// The model `name` built alone: the document with that model as its one
    /// component flattened, so its subsystems are mounted, a self-qualified
    /// `M.a` resolves to `a`, a right-hand-side `D` to the tendency it names
    /// (or a refusal, never a `NaN`) and a `sin` of a `deg` angle takes
    /// radians, as in every other build; then normalized
    /// ([`crate::simulate_array::normalize`]) with its names model-local.
    ///
    /// Names resolve in this model's scope: an explicit selection builds that
    /// model alone, so a name another top-level model declares is not in
    /// scope (see [`Self::whole_document`]).
    fn model_alone(
        file: &mut crate::EsmFile,
        name: &str,
        mut index_sets: HashMap<String, IndexSet>,
    ) -> Result<(NormalizedModel, crate::flatten::FlattenedSystem), SimulateError> {
        let model = file
            .models
            .as_ref()
            .and_then(|m| m.get(name))
            .ok_or_else(|| err(format!("model '{name}' not found in the document")))?
            .clone();
        // The document without its components, cloned, then given the one.
        let models = file.models.take();
        let systems = file.reaction_systems.take();
        let coupling = file.coupling.take();
        let mut alone = file.clone();
        file.models = models;
        file.reaction_systems = systems;
        file.coupling = coupling;
        alone.models = Some(IndexMap::from([(name.to_string(), model)]));
        let flat = crate::flatten::flatten(&alone).map_err(|e| {
            if e.code().is_some() {
                SimulateError::Compile(CompileError::Flatten(e))
            } else {
                err(format!("model '{name}': {e}"))
            }
        })?;
        drop(alone);
        for (k, v) in &flat.index_sets {
            index_sets.entry(k.clone()).or_insert_with(|| v.clone());
        }
        let normalized = crate::simulate_array::normalize(
            BuildInput::Local {
                flat: &flat,
                model: name,
            },
            index_sets,
        )
        .map_err(|e| stage_err(format_args!("model '{name}'"), e))?;
        Ok((normalized, flat))
    }

    /// A document of several models, with none selected, built WHOLE — the
    /// way every other route builds it (the compile path's
    /// `build_array_compiled` and the state-free static evaluation both
    /// `flatten` the document; so do the Julia and Python `esm_problem`). One
    /// dot-namespaced system: each model's variables under `Model.var`, its
    /// subsystems under `Model.Sub.var`, a cross-model reference `Other.x`
    /// bound to the model that declares it, and the document's `coupling`
    /// applied — the flattener's resolution, not a second copy of it. A
    /// provider key is `"<ModelPath>.<param>"`, which is exactly the flattened
    /// name, so every model's data-fed parameters bind.
    ///
    /// Returns the system and the registry it is built against: the
    /// flattened registry carries every mounted subsystem's index sets as well
    /// as the document's own, and the document's declaration wins.
    fn whole_document(
        file: &crate::EsmFile,
        mut index_sets: HashMap<String, IndexSet>,
    ) -> Result<(crate::flatten::FlattenedSystem, HashMap<String, IndexSet>), SimulateError> {
        let flat = crate::flatten::flatten(file).map_err(|e| {
            if e.code().is_some() {
                SimulateError::Compile(CompileError::Flatten(e))
            } else {
                err(format!("flatten the document's models: {e}"))
            }
        })?;
        for (k, v) in &flat.index_sets {
            index_sets.entry(k.clone()).or_insert_with(|| v.clone());
        }
        Ok((flat, index_sets))
    }

    /// Record one evaluation. Under [`BuildContext::refuse_per_cell`] a
    /// per-cell one also stops the build, and the caller returns as soon as
    /// this answers `true`.
    fn record(&mut self, rule: PipelineRule) -> bool {
        let stop = self.opts.refuse_per_cell && matches!(rule.route, Route::PerCell(_));
        if stop {
            self.refused = Some(rule.clone());
        }
        self.rules.push(rule);
        stop
    }

    /// Provider injection: eager CONST materialization; gated deferral.
    ///
    /// The namespace is held as the interpreter's own `ArrMap` (one rehash of
    /// the caller's map, MOVING the values) so the observed-graph loop below
    /// can lend it to the evaluator without the per-observed deep clone of
    /// every provider slab that this map's SR arrays would otherwise cost.
    ///
    /// Returns the DEFERRED providers (with their gates), to be fetched
    /// pre-sliced after value-invention.
    fn inject_providers(
        &mut self,
        const_arrays: HashMap<String, ArrayD<f64>>,
        providers: Vec<(String, Box<dyn DataProvider>)>,
        mut discovered: HashMap<String, ArrayD<f64>>,
        pd_gates: &HashMap<String, ProviderGate>,
    ) -> Result<Vec<GatedProvider>, SimulateError> {
        self.arrays = ArrMap::default();
        let routes = self.array_routes(
            const_arrays
                .keys()
                .chain(providers.iter().map(|(k, _)| k))
                .map(String::as_str),
        )?;
        for (k, a) in const_arrays {
            let Some(name) = routes[&k].clone() else {
                continue;
            };
            let rounded = round_external(&name, a);
            self.arrays.insert(name, rounded);
        }
        let mut gated: Vec<GatedProvider> = Vec::new();
        let n_providers = providers.len();
        for (i, (k, mut prov)) in providers.into_iter().enumerate() {
            self.report(
                PreparePhase::ConstProviders,
                i,
                Some(n_providers),
                k.as_str(),
            )?;
            if let Some(a) = discovered.remove(&k) {
                // Already materialized by the extent-discovery pre-pass; never
                // sampled twice.
                let Some(name) = routes[&k].clone() else {
                    continue;
                };
                self.check_provider_shape(&k, &name, &a)?;
                self.arrays.insert(name.clone(), round_external(&name, a));
            } else if let Some(gate) = pd_gates.get(&k) {
                // Record-derived gate (the rewrite's own metadata.x_esd.pushdown):
                // defer — value-invention must derive the gating set's members
                // before the rows to fetch are known.
                gated.push((k, prov, gate.clone()));
            } else if let Some(gate) = prov.gate_spec() {
                // Provider-declared gate (the fallback protocol) — also deferred.
                gated.push((k, prov, gate));
            } else if let Some(name) = routes[&k].clone() {
                let a = prov
                    .sample()
                    .map_err(|e| err(format!("materialize const provider '{k}': {}", e.0)))?;
                self.log(&format!(
                    "  [prepare] const provider {k} -> {:?}",
                    a.shape()
                ));
                self.check_provider_shape(&k, &name, &a)?;
                self.arrays.insert(name.clone(), round_external(&name, a));
            }
        }
        self.report(
            PreparePhase::ConstProviders,
            n_providers,
            Some(n_providers),
            "",
        )?;
        self.gated_keys = gated.iter().map(|(k, _, _)| k.clone()).collect();
        self.gated_keys.sort();
        Ok(gated)
    }

    /// Refuse a whole-field provider sample `a` (supplied under `key`, held
    /// as `name`) whose shape is not the declared shape of the parameter
    /// `name` spells, with the wording the `providers=` path uses
    /// ([`crate::provider::declared_shape_mismatch`]). `name` is looked up as
    /// it is spelled, then, when dotted, by the part after its first `.` (a
    /// mounted subsystem's parameter under its model-local spelling). A
    /// parameter declared without `shape` takes one value, unless it is
    /// data-fed: its data then decides its shape. Nothing is checked
    /// when `name` spells no parameter or its shape names an index set the
    /// registry cannot size here.
    fn check_provider_shape(
        &self,
        key: &str,
        name: &str,
        a: &ArrayD<f64>,
    ) -> Result<(), SimulateError> {
        let vars = &self.model.variables;
        let Some(var) = vars
            .get(name)
            .or_else(|| name.split_once('.').and_then(|(_, rest)| vars.get(rest)))
            .filter(|v| v.var_type == VariableType::Parameter)
        else {
            return Ok(());
        };
        let declared = match var.shape.as_deref() {
            // A data-fed parameter declared without a shape takes its data's
            // (esm-spec §4.3.4); any other unshaped parameter is one value.
            None if crate::simulate_array::is_data_fed_unshaped(var) => None,
            None => Some(Vec::new()),
            Some(decl) => crate::simulate_array::resolve_declared_shape(decl, &self.index_sets),
        };
        match declared.and_then(|d| {
            crate::provider::declared_shape_mismatch(
                &format!("provider for {key:?}"),
                a.shape(),
                &d,
            )
        }) {
            Some(msg) => Err(err(msg)),
            None => Ok(()),
        }
    }

    /// The name the evaluation namespace holds each array supplied under one
    /// of `keys` (the caller's `const_arrays` keys and the provider keys), or
    /// `None` for a key an exact key for the same variable shadows.
    ///
    /// In the whole-document build that is the declared `Model.var` the key
    /// designates (esm-spec §6.6.2): an exact key wins, a bare key reaches the
    /// one variable it ends, and two keys for one variable, or a key several
    /// variables end, are refused. Model-locally the array is held under its
    /// key, and [`Self::alias_pushdown_names`] publishes the model-local
    /// spellings beside it. A key that names no declared variable (a whole
    /// source's provider, a coupling's source side) is held as it is.
    fn array_routes<'k>(
        &self,
        keys: impl IntoIterator<Item = &'k str>,
    ) -> Result<HashMap<String, Option<String>>, SimulateError> {
        let keys: Vec<&str> = keys.into_iter().collect();
        if let Spelling::ModelLocal(_) = self.spelling {
            return Ok(keys
                .into_iter()
                .map(|k| (k.to_string(), Some(k.to_string())))
                .collect());
        }
        let routed: HashMap<&str, String> = self
            .keys
            .canonical(keys.iter().copied())
            .map_err(crate::problem::provider_key_error)?
            .into_iter()
            .map(|(name, k)| (k, name))
            .collect();
        let mut out = HashMap::with_capacity(keys.len());
        for k in keys {
            let name = match routed.get(k) {
                Some(name) => Some(name.clone()),
                None if self.keys.designates_any(k) => None,
                None => Some(k.to_string()),
            };
            out.insert(k.to_string(), name);
        }
        Ok(out)
    }

    /// The name the evaluation namespace holds a declared variable `name`
    /// under: in the whole-document build the `Model.var` it designates, else
    /// `name` itself.
    fn declared_name(&self, name: &str) -> Result<String, SimulateError> {
        if let Spelling::ModelLocal(_) = self.spelling {
            return Ok(name.to_string());
        }
        Ok(self
            .keys
            .designates(name)
            .map_err(crate::problem::provider_key_error)?
            .into_iter()
            .next()
            .map_or_else(|| name.to_string(), |(n, _)| n))
    }

    /// Provider-key name aliasing.
    ///
    /// Runs for EVERY build, not only the pushdown one. A provider key is
    /// `"<ModelPath>.<param>"` in every binding — that is the `providers`
    /// contract — while the authored expressions of the selected model spell
    /// the same parameter by its model-LOCAL name. Without the alias the
    /// observed graph looks up `hp`, finds no `hp` (only `Probe.hp`), and
    /// evaluates to NaN: a document that read its data correctly, then reported
    /// nothing of it. Gating this on `pushdown_rewrite` made the ingest work
    /// only for callers who also wanted the projection desugar, which is an
    /// unrelated question.
    ///
    /// `pd_coupling` routes an array supplied under a coupling's source side
    /// (`"<source>.<file_variable>"`) onto the variable it feeds. The
    /// whole-document build needs nothing more: [`Self::array_routes`] already
    /// holds every array under the `Model.var` its expressions read.
    fn alias_pushdown_names(&mut self, pd_coupling: &[(String, String)]) {
        if matches!(self.spelling, Spelling::Qualified) {
            for (frm, to) in pd_coupling {
                if self.arrays.contains_key(frm) && !self.arrays.contains_key(to) {
                    let a = self.arrays[frm].clone();
                    self.arrays.insert(to.clone(), a);
                }
            }
            return;
        }
        // `pd_coupling` is empty off the pushdown path, so that half is
        // unchanged; the generic dotted-key → unique-shallowest-bare-tail pass
        // is the one that always runs, and it never overwrites an existing key.
        inject_aliases(&mut self.arrays, pd_coupling);
        // A mounted subsystem's parameter is spelled model-locally in the
        // built model (`Leaf.p`, esm-spec §4.7) while its provider key is the
        // full path (`Parent.Leaf.p`). The bare-tail pass above cannot reach
        // that spelling -- it strips every prefix, not just the model's -- so
        // without this a data-fed parameter inside a subsystem is unbound, and
        // a model that mounts a data-fed leaf to assert on it (§6.6: "declares
        // that test on a component the assembly document itself declares")
        // cannot build.
        //
        // It runs AFTER the bare-tail pass so the model-local key never joins
        // that pass's shallowest-depth tie (a top-level `Parent.p` beside a
        // mounted `Parent.Leaf.p` keeps its bare `p`). It is exact: only a
        // dotted name the built model actually declares (a mounted variable)
        // is published, and in this build that name means the mounted
        // variable, so it REPLACES a same-spelled key a top-level model `Leaf`
        // with its own `p` provider would otherwise have supplied.
        let local: Vec<(String, String)> = self
            .arrays
            .keys()
            .filter_map(|k| {
                let (l, _) = self
                    .keys
                    .spells(k)
                    .into_iter()
                    .find(|(l, how)| *how == KeyMatch::ModelPrefixed && l.contains('.'))?;
                Some((k.clone(), l))
            })
            .collect();
        for (k, l) in local {
            let a = self.arrays[&k].clone();
            self.arrays.insert(l, a);
        }
    }

    /// The model variable a gated provider's slab is published under (see
    /// [`Self::fetch_gated_providers`]): the variable the coupling routes the
    /// provider onto, else the one its key names, else the gate's own target,
    /// each the one name it spells most strongly ([`KeyResolver::strongest`]).
    /// Model-locally a key the
    /// built model does not declare falls back to its last segment, the
    /// spelling the gate's `applies_to` carries.
    fn gated_target(
        &self,
        key: &str,
        gate: &ProviderGate,
        pd_coupling: &[(String, String)],
    ) -> Result<String, SimulateError> {
        let routed = pd_coupling
            .iter()
            .find(|(frm, to)| frm == key || to == key)
            .map(|(_, to)| to.as_str());
        let candidates = routed
            .into_iter()
            .chain([key])
            .chain(gate.applies_to.first().map(String::as_str));
        for c in candidates {
            if let Some(n) = self
                .keys
                .strongest(c)
                .map_err(crate::problem::provider_key_error)?
            {
                return Ok(n);
            }
        }
        let last = routed.unwrap_or_else(|| gate.applies_to.first().map_or(key, String::as_str));
        Ok(last.rsplit('.').next().unwrap_or(last).to_string())
    }

    /// A shaped parameter whose data the document itself supplies (an inline
    /// array, or a scalar broadcast over its grid) is build-time factor data,
    /// bound as the compile path binds it. Runs after every provider and
    /// alias is in place, because a caller's or a provider's array of the
    /// same name stays authoritative, as it does there; a gated provider's
    /// slab, fetched later, does too.
    fn bind_inline_parameters(
        &mut self,
        gated: &[GatedProvider],
        pd_coupling: &[(String, String)],
    ) -> Result<(), SimulateError> {
        let targets: HashSet<String> = gated
            .iter()
            .map(|(k, _, g)| self.gated_target(k, g, pd_coupling))
            .collect::<Result<_, _>>()?;
        for (name, a) in
            crate::simulate_array::inline_parameter_arrays(&self.model, &self.index_sets)
        {
            if !targets.contains(&name) && !self.arrays.contains_key(&name) {
                self.arrays.insert(name, a);
            }
        }
        Ok(())
    }

    /// The CONST-ARRAY registry (CONFORMANCE_SPEC §5.5.5).
    ///
    /// Everything in `arrays` at THIS point is build-time factor data: the
    /// caller's `const_arrays`, the materialized const providers, and the
    /// pushdown coupling aliases. That is exactly the Julia reference's
    /// `const_arrays` registry, so a gather on one of these names is a
    /// CONST-ARRAY gather — an out-of-range index raises
    /// `E_TREEWALK_CONSTARRAY_OOB` rather than silently reading the state
    /// gather's zero ghost, which §5.5.5 says is never a const array's. The
    /// observeds this pipeline evaluates below are inserted into `arrays` as it
    /// goes and are deliberately NOT in the registry: they are observed gathers
    /// and keep the zero-ghost convention.
    fn seal_const_registry(&mut self) {
        self.const_scope = ConstArrayScope::from_names(self.arrays.keys().cloned());
    }

    /// THE FREE-VARIABLE GATE, on this route too (CONFORMANCE_SPEC §5.23).
    ///
    /// A name declared nowhere in the document is a structural error, and both
    /// `esm validate` and the compile path already say so by name. This route
    /// did not: `prepare` evaluates the whole observed graph WHOLESALE through
    /// the shared expression evaluator, upstream of the compile-path gate and
    /// on expressions the compile path never sees again (each observed leaves
    /// here as a materialized field). An undeclared operand therefore fell
    /// through `simulate_array::eval::lookup_variable` to an unbound-name NaN,
    /// and `max(known, undeclaredFloor)` evaluated as `max(known)` — IEEE-754
    /// `max` returns the non-NaN operand, so the operand simply DISAPPEARED and
    /// the answer stayed finite and plausible (finding F25; finding F24 was the
    /// same sentinel reached by a different name on this same route).
    ///
    /// It is the SAME function the compile path calls, not a second copy: two
    /// copies is precisely how one route came to reach a check and the other to
    /// skip it. It runs BEFORE the observed graph, before value invention and
    /// before the gated fetch, so a typo costs a millisecond rather than the
    /// tens of gigabytes a real ISRM fetch moves first.
    ///
    /// `extra_bound` credits the names THIS route's evaluation scope binds that
    /// the model does not declare — the caller's const arrays, the materialized
    /// provider slabs and pushdown aliases already in `arrays`, the scalar
    /// parameter vector, and every derived set's `member_factor` column (fed
    /// into `arrays` later by [`Self::feed_member_factors`], so it cannot be
    /// read off the map yet). Widening the bound set can only prevent a false
    /// positive, which is this gate's cardinal requirement.
    fn check_free_names(&self) -> Result<(), SimulateError> {
        let mut extra: Vec<String> = self.arrays.keys().cloned().collect();
        extra.extend(self.param_names.iter().cloned());
        extra.extend(
            self.index_sets
                .values()
                .filter_map(|is| is.member_factor.clone()),
        );
        crate::simulate_array::check_free_variables(
            &self.model,
            &self.index_sets,
            &extra,
            &self.operators,
        )
        // The compile path's own refusal, unchanged.
        .map_err(SimulateError::Compile)
    }

    /// Observed definitions + the join-free partition.
    ///
    /// Resolve every `join` clause while the ranges still carry their
    /// `{ "from": <index set> }` linkage (`eval_observed` resolves ranges on its
    /// own clone, which erases it):
    ///
    /// * an OVERLAP gate's two range symbols — without this the dense evaluator
    ///   cannot tell which loop symbol each envelope side runs over and declines
    ///   to let the gate drive: correct, but back at `O(∏ranges)`. The
    ///   resolution is infallible (an unresolvable gate simply stays undriven),
    ///   but a factor list of the wrong length or a factor of the wrong rank is
    ///   refused ([`crate::join::check_overlap_factor_ranks`]).
    /// * a value-equality `on` clause, into its `filter` predicate plus the
    ///   drivable [`crate::join::OnGate`] (CONFORMANCE_SPEC §5.5.8). This one is
    ///   NOT optional: `join.on` is the semantics, not an optimisation, and an
    ///   unresolved clause reached the evaluator contributing neither the
    ///   predicate nor the gate — an unfiltered full product, silently. A
    ///   genuinely unresolvable key column is a build error, as it is on the
    ///   compiled path.
    fn collect_observed_defs(&mut self) -> Result<(), SimulateError> {
        let mut defs = observed_defs(&self.model);
        {
            let var_shapes = self
                .built_variables
                .shapes
                .declared_map(|n| self.model.variables.contains_key(n));
            self.ops = std::sync::Arc::new(crate::simulate_array::build_instances(
                self.operators.clone(),
                &self.index_sets,
                var_shapes.clone(),
                &self.extents,
            ));
            for e in defs.values_mut() {
                crate::join::resolve_overlap_syms_expr(e, &var_shapes);
                crate::join::check_overlap_factor_ranks(e, &var_shapes)
                    .map_err(|e| stage_err("resolve join", e))?;
                crate::join::resolve_expr_joins(e, &self.index_sets, &var_shapes)
                    .map_err(|e| stage_err("resolve join", e))?;
            }
        }
        self.join_free = defs
            .iter()
            .filter(|(_, e)| match e {
                Expr::Operator(node) => node.join.as_ref().map(|j| j.is_empty()).unwrap_or(true),
                _ => true,
            })
            .map(|(n, _)| n.clone())
            .collect();
        let deps = observed_dependencies(&self.model, &defs, &self.runtime_fed);
        self.order = observed_order(&deps)?;
        self.order.retain(|name| {
            deps.get(name)
                .is_none_or(|s| !s.reads_state && !s.reads_discrete)
        });
        self.defs = defs;
        self.deps = deps;
        Ok(())
    }

    /// Build-time coordinate path: producer-seeded join-free closure.
    ///
    /// (The Rust analogue of Julia's `_derive_binning_coords` general-eval
    /// seeding; tolerant — an unresolved coordinate degrades to the engine's
    /// own fail-closed contract downstream, exactly as in Python.)
    fn eval_buildtime_coordinates(&mut self) -> Result<(), SimulateError> {
        let seeds: Vec<&Expr> = self
            .model
            .equations
            .iter()
            .filter_map(|eq| match &eq.rhs {
                Expr::Operator(node)
                    if node.op.as_str() == "faq"
                        && node.distinct == Some(true)
                        && node.join.as_ref().map(|j| !j.is_empty()).unwrap_or(false) =>
                {
                    Some(&eq.rhs)
                }
                _ => None,
            })
            .collect();
        if seeds.is_empty() {
            return Ok(());
        }
        let needed = producer_seed_closure(&seeds, &self.deps, &self.join_free);
        let no_extents: HashMap<String, i64> = HashMap::new();
        let coords: Vec<String> = self
            .order
            .iter()
            .filter(|n| needed.contains(*n))
            .cloned()
            .collect();
        let n_coords = coords.len();
        for (i, name) in coords.into_iter().enumerate() {
            self.report(PreparePhase::Coordinates, i, Some(n_coords), name.as_str())?;
            match resolve_observed(&name, &self.defs[&name], &self.index_sets, &no_extents)
                .and_then(|expr| {
                    eval_observed(
                        &name,
                        &expr,
                        &self.scope(&no_extents),
                        self.fill_shape(&name).as_deref(),
                        &self.scalar_shape(&name),
                        self.opts.refuse_per_cell,
                    )
                }) {
                Ok(Evaluated::Refused(why)) => {
                    self.record(PipelineRule {
                        name,
                        kind: "build-time observed",
                        route: Route::PerCell(why),
                    });
                    return Ok(());
                }
                Ok(Evaluated::Field(a, route)) => {
                    self.log(&format!(
                        "  [prepare] build-time coordinate {name} -> {:?}",
                        a.shape()
                    ));
                    if self.record(PipelineRule {
                        name: name.clone(),
                        kind: "build-time observed",
                        route,
                    }) {
                        return Ok(());
                    }
                    self.arrays.insert(name.clone(), a.clone());
                    self.fields.insert(name, a);
                }
                Err(e) => {
                    // Tolerant (mirrors Python's skip_unresolved=True): the
                    // producer then fails with ITS diagnostic if it truly
                    // needed this coordinate.
                    self.log(&format!(
                        "  [prepare] build-time coordinate {name} skipped ({})",
                        e
                    ));
                }
            }
        }
        self.report(PreparePhase::Coordinates, n_coords, Some(n_coords), "")?;
        Ok(())
    }

    /// VALUE INVENTION: the graph derives its own support set.
    fn invent_values(&mut self) -> Result<(), SimulateError> {
        self.report(PreparePhase::ValueInvention, 0, None, "")?;
        // The producers read each scalar parameter from this build's scalar
        // scope, as its observeds do.
        let params: HashMap<String, f64> = self
            .param_names
            .iter()
            .cloned()
            .zip(self.param_vals.iter().copied())
            .collect();
        let vi = run_value_invention_in_scope(
            &self.model,
            &self.index_sets,
            Some(&self.arrays),
            &params,
            &self.ops,
        )
        .map_err(|e| stage_err("value invention", e))?;
        // A member id is needed where a set feeds one back (a `member_factor`,
        // a gated fetch).
        let members = vi.member_ids();
        let mut producers: Vec<&String> = members.keys().collect();
        producers.sort();
        for faq in producers {
            self.rules.push(PipelineRule {
                name: faq.clone(),
                kind: "value invention",
                route: Route::Relational,
            });
        }
        self.members = members;
        self.extents = vi.extents;
        // The instance bodies' ranges are resolved against the extents value
        // invention just counted, as the observed definitions are.
        let var_shapes = self
            .built_variables
            .shapes
            .declared_map(|n| self.model.variables.contains_key(n));
        self.ops = std::sync::Arc::new(crate::simulate_array::build_instances(
            self.operators.clone(),
            &self.index_sets,
            var_shapes,
            &self.extents,
        ));
        Ok(())
    }

    /// Hook 1: derived-set member ids fed back as the member_factor, in
    /// set-name order ([`member_factor_columns`], the compile's own columns),
    /// so the observed event stream and the verbose narration are
    /// deterministic.
    fn feed_member_factors(&mut self) -> Result<(), SimulateError> {
        let columns = member_factor_columns(&self.index_sets, &self.members, None);
        let n_mf = columns.len();
        for (i, column) in columns.into_iter().enumerate() {
            let MemberFactorColumn {
                set: sname,
                factor: mf,
                ids: v,
            } = column;
            self.report(PreparePhase::MemberFactors, i, Some(n_mf), mf.as_str())?;
            self.log(&format!(
                "  [prepare] member_factor {mf} <- |{sname}| = {}",
                v.len()
            ));
            let arr = ArrayD::from_shape_vec(IxDyn(&[v.len()]), v)
                .map_err(|e| err(format!("member factor '{mf}': {e}")))?;
            // The registry names the factor as its model declares it; the
            // whole-document build reads it as `Model.<factor>`.
            let name = self.declared_name(&mf)?;
            self.arrays.insert(name, arr);
        }
        self.report(PreparePhase::MemberFactors, n_mf, Some(n_mf), "")?;
        Ok(())
    }

    /// Hook 2: gated-provider deferral → post-VI pre-sliced fetch.
    ///
    /// Every gate is PLANNED before any of it is issued, so the phase reports one
    /// running "request i of N" across all providers rather than restarting the
    /// count at each one. Planning is pure bookkeeping over the invented members
    /// — it reads nothing and costs nothing next to the fetch it describes.
    fn fetch_gated_providers(
        &mut self,
        gated: Vec<GatedProvider>,
        pd_coupling: &[(String, String)],
    ) -> Result<(), SimulateError> {
        let mut plans: Vec<GatedFetchPlan> = Vec::with_capacity(gated.len());
        for (key, prov, gate) in &gated {
            if gate.applies_to.len() != 1 {
                return Err(err(format!(
                    "gated provider '{key}': applies_to lists {} variables; bind one \
                     provider per variable (providers[\"<ModelPath>.<param>\"]) so each gated \
                     fetch is a single field",
                    gate.applies_to.len()
                )));
            }
            let mut plan =
                gated_fetch_plan(key, gate, &self.index_sets, &self.members, &self.extents)?;
            plan.n_requests = if prov.supports_selection() {
                match &plan.selection[plan.gated_pos] {
                    AxisSel::Indices(idx) => idx
                        .len()
                        .div_ceil(
                            self.opts
                                .problem
                                .gated_fetch_batch
                                .unwrap_or(usize::MAX)
                                .max(1),
                        )
                        .max(1),
                    // Neither is a support set, so `run_gated_fetch` refuses them —
                    // but it refuses them THERE, with a message naming the provider.
                    // Counting them as one request keeps this pass a pure estimate
                    // of the progress denominator rather than a second place that
                    // decides what a gate may be.
                    AxisSel::All | AxisSel::Range { .. } => 1,
                }
            } else {
                1
            };
            plans.push(plan);
        }
        let total_requests: usize = plans.iter().map(|p| p.n_requests).sum();
        let mut issued = 0usize;

        let opts = self.opts;
        let mut report = |phase: PreparePhase, done: usize, total: Option<usize>, item: &str| {
            report_progress(opts, phase, done, total, item)
        };
        for ((key, mut prov, gate), plan) in gated.into_iter().zip(plans) {
            let arr = run_gated_fetch(
                &key,
                prov.as_mut(),
                &plan,
                opts.problem.gated_fetch_batch,
                &mut issued,
                total_requests,
                &mut report,
            )?;
            if arr.shape().get(plan.gated_pos_out).copied() != Some(plan.gated_extent) {
                return Err(err(format!(
                    "gated provider '{key}': fetched compact axis is {:?} but the gating \
                     set extent is {}",
                    arr.shape().get(plan.gated_pos_out),
                    plan.gated_extent
                )));
            }
            // Surface the compact slab under the MODEL variable this provider feeds,
            // spelled as the built model spells it (`Self::gated_target`): its
            // model-local name for one model, `Model.var` for the whole document.
            // From esm 1.0.0 the key IS that variable's namespaced name, so it
            // answers on the routing's `to` side; the `frm` side still answers for a
            // provider registered under the SOURCE's spelling, and the gate's own
            // target is the last resort.
            //
            // ONE registry entry per slab, and it must be THIS provider's own: the SR
            // slabs are hundreds of MB so aliasing would deep-copy, and — load-bearing
            // for CORRECTNESS, not only for memory — sibling sources may feed the SAME
            // variable name. `isrm.esm` fetches one zarr array at three emission
            // layers through three providers that differ in nothing but the
            // `{"fixed": [layer]}` axis of their `gated_select`. Publishing a slab
            // under every key with the same dotted TAIL (as the Julia and Python hooks
            // once did) makes all three providers claim all three keys, so whichever
            // is written last silently wins for all of them and every layer is
            // contracted against one arbitrary sibling's slab. Both arms below match
            // a key EXACTLY; never a name-tail expansion.
            let target = self.gated_target(&key, &gate, pd_coupling)?;
            self.log(&format!(
                "  [prepare] gated fetch {key} -> {target} {:?}",
                arr.shape()
            ));
            self.arrays
                .insert(target.clone(), round_external(&target, arr));
        }
        self.report(
            PreparePhase::GatedFetch,
            total_requests,
            Some(total_requests),
            "",
        )?;
        Ok(())
    }

    /// Narrow the observed graph to the dependency cone of
    /// [`crate::problem::ProblemOptions::observed_cone`], when the built model has nothing to
    /// integrate.
    ///
    /// Runs AFTER the coordinate pre-pass, value invention and member-factor
    /// feedback, and leaves all three whole: they size the derived index sets,
    /// so every observed an extent comes from has been evaluated already,
    /// whether or not it is in the cone. The gated fetch runs after this pass
    /// and is not narrowed by it either. What is narrowed is the observed
    /// graph — the one pass whose cost grows with the document rather than
    /// with the request.
    ///
    /// Every observed an index set's fields name (a ragged set's `offsets`
    /// and `values`, a derived set's `member_factor`) is in the cone whatever
    /// the request: a range over the set reads it without naming it.
    ///
    /// The cone is the requested observeds and, transitively, every observed
    /// their definitions NAME: any string anywhere in a definition (a bare
    /// reference, a `join.on` column, a table, a range) that is an observed's
    /// key. That over-approximates the evaluator's own reads, which is the
    /// safe direction: an observed in the cone is evaluated exactly as it
    /// would have been, from the same inputs, so its value is bit-identical.
    ///
    /// A requested name addresses the keys [`crate::problem::observed_field`]
    /// could resolve it to: the key itself, the key under the built model's
    /// prefix, or — for a bare name — every key it is the tail of. A name that
    /// addresses no observed (a data-fed parameter, a value-invention buffer, a
    /// coordinate) seeds nothing; the caller decides whether it is known.
    ///
    /// A model WITH state is left whole: its build-time fields feed a
    /// right-hand side, and which of them it reads is the compiler's business,
    /// not the request's.
    fn prune_to_observed_cone(&mut self) {
        let Some(requested) = &self.opts.problem.observed_cone else {
            return;
        };
        if self.has_state() {
            return;
        }
        let prefix = match &self.spelling {
            Spelling::ModelLocal(m) => Some(format!("{m}.")),
            Spelling::Qualified => None,
        };
        let reads: HashMap<&str, HashSet<String>> = self
            .defs
            .iter()
            .map(|(n, e)| (n.as_str(), crate::observed_cone::named_strings(e)))
            .collect();
        let pinned = crate::observed_cone::index_set_names(self.index_sets.values());
        let seeds = self
            .defs
            .keys()
            .filter(|k| {
                crate::observed_cone::addressed_by_any(k, &pinned, prefix.as_deref())
                    || requested
                        .iter()
                        .any(|n| crate::observed_cone::addresses(k, n, prefix.as_deref()))
            })
            .cloned();
        let cone =
            crate::observed_cone::closure(seeds, |n| self.defs.contains_key(n), |n| reads.get(n));
        let before = self.order.len();
        self.cone_applied = before > 0;
        self.order
            .retain(|n| cone.contains(n) || self.fields.contains_key(n));
        self.log(&format!(
            "  [prepare] observed cone: {} of {before} observeds",
            self.order.len()
        ));
    }

    /// Evaluate, ahead of the gated fetch, every observed that does not read a
    /// gated slab, directly or through another observed.
    ///
    /// Their inputs are all in place by now, so this changes no value — only
    /// WHEN they are evaluated. It is what lets a strict compiler refuse a
    /// document whose refusal has nothing to do with the gated data before
    /// the fetch moves it (a real source-receptor fetch is gigabytes). The
    /// observeds that do read a gated slab follow the fetch, as before.
    fn eval_observeds_before_fetch(
        &mut self,
        gated: &[GatedProvider],
        pd_coupling: &[(String, String)],
    ) -> Result<(), SimulateError> {
        // A gate that does not name exactly one variable is refused by the
        // fetch itself, with its own message; nothing is moved ahead of that.
        if gated.is_empty() || gated.iter().any(|(_, _, g)| g.applies_to.len() != 1) {
            return Ok(());
        }
        let gated_targets: HashSet<String> = gated
            .iter()
            .map(|(key, _, gate)| self.gated_target(key, gate, pd_coupling))
            .collect::<Result<_, _>>()?;
        let after = self.deps.reaching(&gated_targets);
        self.eval_observeds(&after, false)
    }

    /// Evaluate the whole observed graph in dependency order.
    ///
    /// Every observed that still needs evaluating, counted up front: `order`
    /// includes the coordinate pre-pass's products, and a `total` that a `continue`
    /// silently makes unreachable is a bar that never fills.
    fn eval_observed_graph(&mut self) -> Result<(), SimulateError> {
        self.eval_observeds(&HashSet::new(), true)
    }

    /// One pass over the pending observeds, skipping `skip` and what an
    /// earlier pass evaluated. The last pass (`last`) moves every evaluated
    /// observed into `fields`; so does any pass that ends in a refusal.
    fn eval_observeds(&mut self, skip: &HashSet<String>, last: bool) -> Result<(), SimulateError> {
        let pending: Vec<String> = self
            .order
            .iter()
            .filter(|n| !self.fields.contains_key(*n))
            .cloned()
            .collect();
        if self.obs_done == 0 {
            self.obs_total = pending.len();
        }
        let n_pending = self.obs_total;
        for name in pending.iter() {
            if skip.contains(name) || self.evaluated.contains(name) {
                continue;
            }
            self.report(
                PreparePhase::Observeds,
                self.obs_done,
                Some(n_pending),
                name.as_str(),
            )?;
            self.obs_done += 1;
            self.evaluated.insert(name.clone());
            let t = std::time::Instant::now();
            // Resolved once, for the row-dedup attempt and the evaluation as
            // written alike.
            let expr = resolve_observed(name, &self.defs[name], &self.index_sets, &self.extents)?;
            // A rule that reads its driving row only through key columns is
            // evaluated once per distinct key signature (crate::row_dedup).
            if let Some((a, route)) = self.eval_observed_dedup(name, &expr)? {
                self.log(&format!(
                    "  [prepare] {name:<24} shape={:?}  {:>9.4} s (row-dedup)",
                    a.shape(),
                    t.elapsed().as_secs_f64()
                ));
                if self.record(PipelineRule {
                    name: name.clone(),
                    kind: "build-time observed",
                    route,
                }) {
                    break;
                }
                self.arrays.insert(name.clone(), a);
                continue;
            }
            let (a, route) = match eval_observed(
                name,
                &expr,
                &self.scope(&self.extents),
                self.fill_shape(name).as_deref(),
                &self.scalar_shape(name),
                self.opts.refuse_per_cell,
            )? {
                Evaluated::Field(a, route) => (a, route),
                Evaluated::Refused(why) => {
                    self.record(PipelineRule {
                        name: name.clone(),
                        kind: "build-time observed",
                        route: Route::PerCell(why),
                    });
                    break;
                }
            };
            self.log(&format!(
                "  [prepare] {name:<24} shape={:?}  {:>9.4} s",
                a.shape(),
                t.elapsed().as_secs_f64()
            ));
            if self.record(PipelineRule {
                name: name.clone(),
                kind: "build-time observed",
                route,
            }) {
                break;
            }
            // Into the evaluation namespace ONLY while later observeds may still
            // read it; each is MOVED into `fields` after the loop rather than held
            // in both maps at once.
            self.arrays.insert(name.clone(), a);
        }
        if !last && self.refused.is_none() {
            return Ok(());
        }
        for name in &pending {
            if let Some(a) = self.arrays.remove(name) {
                self.fields.insert(name.clone(), a);
            }
        }
        if self.refused.is_some() {
            return Ok(());
        }
        self.report(PreparePhase::Observeds, n_pending, Some(n_pending), "")?;
        Ok(())
    }

    /// [`crate::row_dedup`]: evaluate `name` over one representative row per
    /// distinct key signature and scatter the result back, or `None` to
    /// evaluate it as written. Only a rule the tape or the reference evaluator
    /// takes over whole arrays is kept; a per-cell walk or a refusal is evaluated as written, so
    /// what is recorded or refused is what it would have been. That second
    /// evaluation happens only on a refusal, which ends the pipeline; the
    /// syntactic [`crate::row_dedup::plan`] declines every other rule before
    /// anything is evaluated or copied.
    fn eval_observed_dedup(
        &mut self,
        name: &str,
        expr: &Expr,
    ) -> Result<Option<(ArrayD<f64>, Route)>, SimulateError> {
        // Only under a strict compiler: the reference interpreter is the
        // oracle the fast tiers are checked against, and promises nothing
        // about speed.
        if !self.opts.refuse_per_cell || !crate::row_dedup::row_dedup_enabled() {
            return Ok(None);
        }
        let Some(mut plan) = crate::row_dedup::plan_in(name, expr, &self.arrays, &self.operators)
        else {
            return Ok(None);
        };
        let fill = self.fill_shape(name).map(|mut s| {
            if plan.axis < s.len() && s[plan.axis] == plan.rows {
                s[plan.axis] = plan.reps;
            }
            s
        });
        let mut scalar = self.scalar_shape(name);
        if plan.axis < scalar.len() && scalar[plan.axis] == plan.rows {
            scalar[plan.axis] = plan.reps;
        }
        let mut names: Vec<String> = Vec::with_capacity(plan.columns.len());
        for (n, a) in std::mem::take(&mut plan.columns) {
            names.push(n.clone());
            self.arrays.insert(n, a);
        }
        let res = eval_observed(
            name,
            &plan.expr,
            &self.scope(&self.extents),
            fill.as_deref(),
            &scalar,
            self.opts.refuse_per_cell,
        );
        for n in &names {
            self.arrays.remove(n);
        }
        Ok(match res {
            Ok(Evaluated::Field(a, route @ (Route::Tape | Route::Whole))) => {
                let out = crate::row_dedup::expand(&plan, a).map(|a| (a, route));
                if out.is_some() {
                    crate::row_dedup::note_applied();
                }
                out
            }
            // Any other route or a refusal: evaluate as written, so what is
            // recorded and refused is exactly what it would have been.
            _ => None,
        })
    }

    /// Assemble the [`PreparedBuild`] artifact from the accumulated state.
    fn finish(mut self, doc: JsonValue) -> PreparedBuild {
        // The namespace is dropped here, so a data-fed parameter's array is
        // MOVED out of it, never copied.
        let data_fields: HashMap<String, ArrayD<f64>> = self
            .model
            .variables
            .iter()
            .filter(|(_, v)| v.update.as_ref().is_some_and(crate::data_fed::is_data_fed))
            .filter_map(|(name, _)| Some((name.clone(), self.arrays.remove(name)?)))
            .collect();
        // Every field the record at `t0` decided: the pinned parameters and
        // each observed reading one, directly or through another observed.
        let time_pinned: HashSet<String> = if self.time_pinned.is_empty() {
            HashSet::new()
        } else {
            let deps = observed_dependencies(&self.model, &self.defs, &self.time_pinned);
            self.defs
                .keys()
                .filter(|n| deps.get(n.as_str()).is_some_and(|s| s.reads_discrete))
                .cloned()
                .chain(self.time_pinned.iter().cloned())
                .collect()
        };
        PreparedBuild {
            doc,
            model_name: match self.spelling {
                Spelling::ModelLocal(m) => Some(m),
                Spelling::Qualified => None,
            },
            file: self.file,
            flattened: self.flattened,
            products: crate::problem::BuildProducts {
                fields: self.fields,
                members: self.members,
                extents: self.extents,
                gated_provider_keys: self.gated_keys,
                built_variables: self.built_variables,
                time_pinned,
                ..Default::default()
            },
            data_fields,
            rules: self.rules,
            refused: self.refused,
            observed_cone_applied: self.cone_applied,
        }
    }
}

// --------------------------------------------------------------------------- //
// The adapter EsmProblem construction goes through.
// --------------------------------------------------------------------------- //

/// Run the build pipeline for [`crate::problem::esm_problem`] over `opts`.
///
/// Consumes `opts`'s CONST providers and const arrays: they are moved into the
/// pipeline, which is the one place they are used.
pub(crate) fn run_build_pipeline(
    doc: &JsonValue,
    t0: f64,
    opts: &mut crate::problem::ProblemOptions,
) -> Result<PreparedBuild, crate::simulate::SimulateError> {
    let const_arrays = std::mem::take(&mut opts.const_arrays);
    // The CONST providers, in key order, when the caller asked for this
    // pipeline; the run-time executor takes the rest.
    let takes = crate::problem::pipeline_takes_providers(opts);
    let mut keys: Vec<String> = opts
        .providers
        .iter()
        .filter(|(_, p)| takes && p.refresh_times().is_empty())
        .map(|(k, _)| k.clone())
        .collect();
    keys.sort();
    let providers = keys
        .into_iter()
        .map(|k| {
            let p = opts.providers.remove(&k).expect("a key of the map");
            (k, p)
        })
        .collect();
    // The TIME-VARYING providers, lent to the pipeline: it consumes them for
    // a document with nothing to integrate (sampled at `t0`, see
    // [`run_prepare`]) and hands every other one back for the run-time
    // executor.
    let mut timed: Vec<(String, Box<dyn DataProvider>)> = Vec::new();
    if takes {
        let mut keys: Vec<String> = opts
            .providers
            .iter()
            .filter(|(_, p)| !p.refresh_times().is_empty())
            .map(|(k, _)| k.clone())
            .collect();
        keys.sort();
        for k in keys {
            let p = opts.providers.remove(&k).expect("a key of the map");
            timed.push((k, p));
        }
    }
    let ctx = BuildContext {
        problem: opts,
        t0,
        refuse_per_cell: opts.compiler.unwrap_or_default().is_strict(),
    };
    let prepared = run_prepare(doc, const_arrays, providers, &mut timed, &ctx);
    opts.providers.extend(timed);
    prepared
}

/// Whether `file`'s one model built alone is the whole system `flatten(file)`
/// builds: the document is that model, with no reaction system and no
/// coupling beside it, which is exactly what [`BuildState::model_alone`]
/// removes.
fn builds_alone_as_itself(file: &crate::EsmFile) -> bool {
    file.models.as_ref().is_some_and(|m| m.len() == 1)
        && file.reaction_systems.as_ref().is_none_or(|r| r.is_empty())
        && file.coupling.as_ref().is_none_or(|c| c.is_empty())
}

/// Whether `doc` still carries an unresolved §4.7 mount — a `models.<k>` /
/// `reaction_systems.<k>` `{ref}` or a `subsystems.<k>` `{ref}`.
///
/// Distinguishes an AUTHORED document, whose mounted leaves still have their
/// `metaparameters` to be closed at the edge, from one an earlier load already
/// inlined, where those declarations have been consumed and the loader-API
/// names they served have nothing left to bind.
fn document_has_unresolved_mount(doc: &JsonValue) -> bool {
    let Some(obj) = doc.as_object() else {
        return false;
    };
    for kind in ["models", "reaction_systems"] {
        let Some(comps) = obj.get(kind).and_then(|v| v.as_object()) else {
            continue;
        };
        for comp in comps.values() {
            if comp.get("ref").is_some() {
                return true;
            }
            if let Some(subs) = comp.get("subsystems").and_then(|v| v.as_object())
                && subs.values().any(|s| s.get("ref").is_some())
            {
                return true;
            }
        }
    }
    false
}

#[cfg(test)]
mod first_cell_stop_tests {
    //! A strict compiler never walks a pipeline observed past its first cell:
    //! the walk stops there and the observed is lowered on the tape instead —
    //! counted with the evaluator's per-cell test hook, never timed.

    use crate::compile_error::CompileError;
    use crate::problem::{Compiler, ProblemOptions, esm_problem};
    use crate::simulate::SimulateError;
    use crate::simulate_array::per_cell_cells;
    use serde_json::{Value, json};

    fn doc(n: usize, variables: Value, equations: Value) -> Value {
        json!({
            "esm": "2.0.0",
            "metadata": {"name": "FirstCellStop"},
            "index_sets": {"rows": {"kind": "interval", "size": n}},
            "models": {"Rel": {"variables": variables, "equations": equations}},
        })
    }

    /// `left[i] = 10 i` and its running sum `cum[i] = Σ_{j ≤ i} left[j]`,
    /// which the reference evaluator sweeps as a prefix scan.
    fn cumulative(n: usize) -> Value {
        doc(
            n,
            json!({
                "left": {"type": "unknown", "units": "1", "shape": ["rows"]},
                "cum": {"type": "unknown", "units": "1", "shape": ["rows"]},
            }),
            json!([
                {"lhs": "left",
                 "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                         "ranges": {"i": {"from": "rows"}},
                         "expr": {"op": "*", "args": [10, "i"]}}},
                {"lhs": "cum",
                 "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                         "ranges": {"i": {"from": "rows"}, "j": {"from": "rows"}},
                         "filter": {"op": "<=", "args": ["j", "i"]},
                         "expr": {"op": "index", "args": ["left", "j"]}}},
            ]),
        )
    }

    /// `s[1] = 1`, `s[k] = s[k-1] + 1`: a causal self-reference, swept cell by
    /// cell.
    fn recurrence(n: usize) -> Value {
        doc(
            n,
            json!({"s": {"type": "unknown", "units": "1", "shape": ["rows"]}}),
            json!([
                {"lhs": "s",
                 "rhs": {"op": "faq", "args": [], "output_idx": ["k"],
                         "ranges": {"k": {"from": "rows"}},
                         "expr": {"op": "ifelse", "args": [
                             {"op": "<=", "args": ["k", 1]},
                             1.0,
                             {"op": "+", "args": [
                                 {"op": "index", "args": ["s", {"op": "-", "args": ["k", 1]}]},
                                 1.0]}]}}},
            ]),
        )
    }

    fn build(d: &Value, compiler: Compiler) -> Result<crate::problem::EsmProblem, SimulateError> {
        esm_problem(
            d,
            (0.0, 1.0),
            ProblemOptions {
                compiler: Some(compiler),
                build_pipeline: true,
                ..Default::default()
            },
        )
    }

    const LARGE: usize = 200_000;

    /// `native`'s build of `d` and the cells the per-cell walks evaluated on
    /// the way to it.
    fn native_cells(d: &Value) -> (crate::problem::EsmProblem, u64) {
        let before = per_cell_cells();
        let prob = build(d, Compiler::Native).expect("native builds it on the tape");
        (prob, per_cell_cells() - before)
    }

    fn bits(p: &crate::problem::EsmProblem, name: &str) -> Vec<u64> {
        crate::problem::observed_field(p, name)
            .expect("field")
            .iter()
            .map(|x| x.to_bits())
            .collect()
    }

    /// Each of the two observeds is a `faq` the reference evaluator would
    /// walk per cell, so each costs one walked cell before it goes to the
    /// tape: two, whatever the size.
    #[test]
    fn a_large_prefix_scan_is_taped_after_one_walked_cell_per_observed() {
        let (native, cells) = native_cells(&cumulative(LARGE));
        assert!(
            cells <= 2,
            "each walk must stop at its first cell, walked {cells}"
        );

        // The reference evaluator still walks every cell of both, to the same
        // answer.
        let before = per_cell_cells();
        let prob = build(&cumulative(LARGE), Compiler::Interpreter).expect("interpreter");
        assert_eq!(per_cell_cells() - before, 2 * LARGE as u64);
        let cum = crate::problem::observed_field(&prob, "Rel.cum").expect("cum");
        let n = LARGE as f64;
        assert_eq!(cum.iter().last().copied(), Some(5.0 * n * (n + 1.0)));
        assert_eq!(bits(&native, "Rel.cum"), bits(&prob, "Rel.cum"));
    }

    #[test]
    fn a_large_recurrence_is_taped_without_a_walked_cell() {
        let (native, cells) = native_cells(&recurrence(LARGE));
        assert_eq!(cells, 0, "a recurrence goes straight to the tape's sweep");

        let before = per_cell_cells();
        let prob = build(&recurrence(LARGE), Compiler::Interpreter).expect("interpreter");
        assert_eq!(per_cell_cells() - before, LARGE as u64);
        let s = crate::problem::observed_field(&prob, "Rel.s").expect("s");
        assert_eq!(s.iter().last().copied(), Some(LARGE as f64));
        assert_eq!(bits(&native, "Rel.s"), bits(&prob, "Rel.s"));
    }

    /// A record-to-cell binning producer whose record coordinate `X` is a
    /// running sum, so the build-time coordinate pass ahead of value invention
    /// must walk it per cell. Cells are the unit squares `[k-1, k] × [0, 1]`.
    fn binning(
        n: usize,
    ) -> (
        Value,
        std::collections::HashMap<String, ndarray::ArrayD<f64>>,
    ) {
        let d = json!({
            "esm": "2.0.0",
            "metadata": {"name": "FirstCellStopCoordinates"},
            "index_sets": {
                "records": {"kind": "interval", "size": n},
                "cells": {"kind": "interval", "size": n},
                "occupied": {"kind": "derived", "from_faq": "bins"}
            },
            "models": {"Rel": {
                "variables": {
                    "step": {"type": "parameter", "units": "1", "shape": ["records"]},
                    "Y": {"type": "parameter", "units": "1", "shape": ["records"]},
                    "W": {"type": "parameter", "units": "1", "shape": ["cells"]},
                    "S": {"type": "parameter", "units": "1", "shape": ["cells"]},
                    "E": {"type": "parameter", "units": "1", "shape": ["cells"]},
                    "N": {"type": "parameter", "units": "1", "shape": ["cells"]},
                    "X": {"type": "unknown", "units": "1", "shape": ["records"]},
                    "present": {"type": "unknown", "shape": ["occupied"]}
                },
                "equations": [
                    {"lhs": "X",
                     "rhs": {"op": "faq", "args": [], "output_idx": ["r"],
                             "ranges": {"r": {"from": "records"}, "q": {"from": "records"}},
                             "filter": {"op": "<=", "args": ["q", "r"]},
                             "expr": {"op": "index", "args": ["step", "q"]}}},
                    {"lhs": {"op": "index", "args": ["present", "e"]},
                     "rhs": {"op": "faq", "id": "bins",
                             "args": ["X", "Y", "W", "S", "E", "N"],
                             "semiring": "bool_and_or", "distinct": true,
                             "output_idx": ["e"],
                             "ranges": {"r": {"from": "records"}, "c": {"from": "cells"}},
                             "join": [{"overlap": {"src_env": ["X", "Y"],
                                                   "tgt_env": ["W", "S", "E", "N"],
                                                   "eps": 0.0}}],
                             "key": "c",
                             "expr": {"op": "true", "args": []}}}
                ]
            }}
        });
        let col = |f: &dyn Fn(usize) -> f64| {
            ndarray::ArrayD::from_shape_vec(ndarray::IxDyn(&[n]), (0..n).map(f).collect())
                .expect("shape")
        };
        let arrays = [
            // X[r] = r - 1/2, the centre of cell r.
            ("step", col(&|k| if k == 0 { 0.5 } else { 1.0 })),
            ("Y", col(&|_| 0.5)),
            ("W", col(&|k| k as f64)),
            ("S", col(&|_| 0.0)),
            ("E", col(&|k| k as f64 + 1.0)),
            ("N", col(&|_| 1.0)),
        ]
        .into_iter()
        .map(|(k, v)| (k.to_string(), v))
        .collect();
        (d, arrays)
    }

    #[test]
    fn a_large_per_cell_coordinate_is_taped_after_at_most_one_walked_cell() {
        let run = |n: usize, compiler: Compiler| {
            let (d, const_arrays) = binning(n);
            let before = per_cell_cells();
            let r = esm_problem(
                &d,
                (0.0, 1.0),
                ProblemOptions {
                    compiler: Some(compiler),
                    build_pipeline: true,
                    const_arrays,
                    ..Default::default()
                },
            );
            (r, per_cell_cells() - before)
        };
        let (native, cells) = run(LARGE, Compiler::Native);
        let native = native.expect("native builds it on the tape");
        assert!(
            cells <= 1,
            "the coordinate pass must stop at its first cell, walked {cells}"
        );
        assert_eq!(native.members()["bins"].len(), LARGE, "one record per cell");

        let (interp, cells) = run(1000, Compiler::Interpreter);
        let prob = interp.expect("the interpreter builds it");
        assert_eq!(cells, 1000);
        assert_eq!(prob.members()["bins"].len(), 1000, "one record per cell");
        let (native_small, _) = run(1000, Compiler::Native);
        let native_small = native_small.expect("native");
        assert_eq!(native_small.members()["bins"], prob.members()["bins"]);
    }

    /// A document error in the first cell is still the document's error, not
    /// a refusal: the first cell is evaluated for exactly this. Here the
    /// running sum gathers a supplied const array out of range.
    #[test]
    fn an_error_in_the_first_cell_is_not_a_refusal() {
        let d = doc(
            3,
            json!({
                "table": {"type": "parameter", "units": "1", "shape": ["rows"]},
                "cum": {"type": "unknown", "units": "1", "shape": ["rows"]},
            }),
            json!([
                {"lhs": "cum",
                 "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                         "ranges": {"i": {"from": "rows"}, "j": {"from": "rows"}},
                         "filter": {"op": "<=", "args": ["j", "i"]},
                         "expr": {"op": "index", "args": ["table", {"op": "+", "args": ["j", 10]}]}}},
            ]),
        );
        for compiler in [Compiler::Native, Compiler::Interpreter] {
            let table = ndarray::ArrayD::from_shape_vec(ndarray::IxDyn(&[3]), vec![1.0, 2.0, 3.0])
                .expect("shape");
            let err = esm_problem(
                &d,
                (0.0, 1.0),
                ProblemOptions {
                    compiler: Some(compiler),
                    build_pipeline: true,
                    const_arrays: [("table".to_string(), table)].into_iter().collect(),
                    ..Default::default()
                },
            )
            .expect_err("an out-of-range gather");
            assert!(
                !matches!(
                    err,
                    SimulateError::Compile(CompileError::CompilerRefusedRule { .. })
                ),
                "[{compiler}] {err}"
            );
            assert!(err.to_string().contains("OOB"), "[{compiler}] {err}");
        }
    }

    /// A document error that first appears in a LATER cell, past where the
    /// walk stopped, is still reported: native evaluates every cell on the
    /// tape, which latches the same error the interpreter raises. Here the
    /// gather is out of range only at the last output cell.
    #[test]
    fn an_error_in_a_later_cell_is_reported_by_the_tape() {
        let d = doc(
            3,
            json!({
                "table": {"type": "parameter", "units": "1", "shape": ["rows"]},
                "cum": {"type": "unknown", "units": "1", "shape": ["rows"]},
            }),
            json!([
                {"lhs": "cum",
                 "rhs": {"op": "faq", "args": [], "output_idx": ["i"],
                         "ranges": {"i": {"from": "rows"}, "j": {"from": "rows"}},
                         "filter": {"op": "<=", "args": ["j", "i"]},
                         "expr": {"op": "index", "args": ["table", {"op": "+", "args": ["i", 1]}]}}},
            ]),
        );
        let run = |compiler| {
            let table = ndarray::ArrayD::from_shape_vec(ndarray::IxDyn(&[3]), vec![1.0, 2.0, 3.0])
                .expect("shape");
            esm_problem(
                &d,
                (0.0, 1.0),
                ProblemOptions {
                    compiler: Some(compiler),
                    build_pipeline: true,
                    const_arrays: [("table".to_string(), table)].into_iter().collect(),
                    ..Default::default()
                },
            )
            .expect_err("the last cell gathers out of range")
        };
        let native = run(Compiler::Native);
        let interp = run(Compiler::Interpreter);
        assert!(interp.to_string().contains("OOB"), "{interp}");
        assert_eq!(native.to_string(), interp.to_string());
    }
}

#[cfg(test)]
mod mounted_subsystem_tests {
    //! The build pipeline makes `flatten`'s rewrites on the authored model, and
    //! a mounted subsystem's equations and declarations must be in scope for
    //! them, as they are on the array runtime.
    use crate::problem::{Compiler, ProblemOptions, esm_problem, observed_field, solve};
    use serde_json::{Value, json};

    /// `P` holds a state `c` with `D(c) = -c` and the observed `name = rhs`;
    /// its subsystem `North` holds a state `u` with `D(u) = k`, an angle
    /// `theta = 40 deg` and the state-dependent observed `v = 2*u`.
    fn doc(name: &str, units: &str, rhs: Value) -> Value {
        json!({
            "esm": "2.0.0",
            "metadata": {"name": "Mounted"},
            "models": {"P": {
                "variables": {
                    "c": {"type": "unknown", "units": "1", "default": 1.0},
                    name: {"type": "unknown", "units": units}
                },
                "equations": [
                    {"lhs": {"op": "D", "args": ["c"], "wrt": "t"},
                     "rhs": {"op": "-", "args": ["c"]}},
                    {"lhs": name, "rhs": rhs}
                ],
                "subsystems": {"North": {
                    "variables": {
                        "u": {"type": "unknown", "units": "1", "default": 2.0},
                        "k": {"type": "parameter", "units": "1/s", "default": 0.5},
                        "theta": {"type": "parameter", "units": "deg", "default": 40.0},
                        "v": {"type": "unknown", "units": "1"}
                    },
                    "equations": [
                        {"lhs": {"op": "D", "args": ["u"], "wrt": "t"},
                         "rhs": "k"},
                        {"lhs": "v", "rhs": {"op": "*", "args": [2.0, "u"]}}
                    ]
                }}
            }}
        })
    }

    /// The document through the build pipeline (which takes the raw JSON), or
    /// straight to the array runtime (the typed document).
    fn built(d: &Value, compiler: Compiler, build_pipeline: bool) -> crate::problem::EsmProblem {
        let opts = ProblemOptions {
            compiler: Some(compiler),
            build_pipeline,
            ..Default::default()
        };
        let prob = if build_pipeline {
            esm_problem(d, (0.0, 1.0), opts)
        } else {
            let file = crate::load_string(&d.to_string()).expect("loads");
            esm_problem(&file, (0.0, 1.0), opts)
        };
        prob.unwrap_or_else(|e| panic!("[{compiler}, pipeline {build_pipeline}] {e}"))
    }

    /// `name` at `t = 0`, from a solve that reports it.
    fn at_t0(prob: &crate::problem::EsmProblem, name: &str) -> f64 {
        let sol = solve(
            prob,
            &crate::SolveOptions {
                saveat: Some(vec![0.0]),
                output_observed: vec![name.to_string()],
                ..Default::default()
            },
        )
        .unwrap_or_else(|e| panic!("{e}"));
        sol.get(name)
            .unwrap_or_else(|| panic!("no {name} row: {:?}", sol.state_variable_names))[0]
    }

    #[test]
    fn a_degree_angle_in_a_subsystem_takes_radians() {
        let d = doc("y", "1", json!({"op": "sin", "args": ["North.theta"]}));
        let want = 40.0f64.to_radians().sin();
        for compiler in [Compiler::Native, Compiler::Interpreter] {
            for pipeline in [false, true] {
                let prob = built(&d, compiler, pipeline);
                assert_eq!(at_t0(&prob, "y"), want, "[{compiler}, pipeline {pipeline}]");
            }
            // What the pipeline materialized at build time.
            let prob = built(&d, compiler, true);
            let y = observed_field(&prob, "y").expect("y");
            assert_eq!(
                y.iter().copied().collect::<Vec<_>>(),
                [want],
                "[{compiler}]"
            );
        }
    }

    /// `D(North.u)` is the subsystem's tendency, `North.k`: state-free, so the
    /// pipeline materializes it at build time.
    #[test]
    fn a_time_derivative_of_a_subsystem_state_resolves() {
        let d = doc(
            "z",
            "1/s",
            json!({"op": "D", "args": ["North.u"], "wrt": "t"}),
        );
        for compiler in [Compiler::Native, Compiler::Interpreter] {
            for pipeline in [false, true] {
                let prob = built(&d, compiler, pipeline);
                assert_eq!(at_t0(&prob, "z"), 0.5, "[{compiler}, pipeline {pipeline}]");
            }
            let prob = built(&d, compiler, true);
            let z = observed_field(&prob, "z").expect("z");
            assert_eq!(z.iter().copied().collect::<Vec<_>>(), [0.5], "[{compiler}]");
        }
    }

    /// A mounted subsystem's observed that reads its state, `North.v = 2*North.u`,
    /// has no value at build time. The pipeline leaves it to the run, where it
    /// is evaluated like any other observed, rather than failing the build on
    /// the state it cannot read.
    #[test]
    fn a_mounted_state_dependent_observed_is_evaluated_at_run_time() {
        let d = doc("y", "1", json!({"op": "sin", "args": ["North.theta"]}));
        for compiler in [Compiler::Native, Compiler::Interpreter] {
            for pipeline in [false, true] {
                let prob = built(&d, compiler, pipeline);
                let sol = solve(
                    &prob,
                    &crate::SolveOptions {
                        saveat: Some(vec![0.0]),
                        output_observed: vec!["North.v".to_string()],
                        ..Default::default()
                    },
                )
                .unwrap_or_else(|e| panic!("[{compiler}, pipeline {pipeline}] {e}"));
                let v = sol
                    .get("P.North.v")
                    .unwrap_or_else(|| panic!("no North.v row: {:?}", sol.state_variable_names));
                assert_eq!(v[0], 4.0, "[{compiler}, pipeline {pipeline}]");
            }
        }
    }

    /// The same for a top-level observed that reads a state, `w = 2*c`.
    #[test]
    fn a_top_level_state_dependent_observed_is_evaluated_at_run_time() {
        let d = doc("w", "1", json!({"op": "*", "args": [2.0, "c"]}));
        for compiler in [Compiler::Native, Compiler::Interpreter] {
            for pipeline in [false, true] {
                let prob = built(&d, compiler, pipeline);
                assert_eq!(at_t0(&prob, "w"), 2.0, "[{compiler}, pipeline {pipeline}]");
            }
        }
    }
}

#[cfg(test)]
mod whole_document_tests {
    //! The whole-document build (several models, none selected): how its names
    //! are spelled, and the flattened system it hands the compile path.

    use super::{BuildContext, Spelling, run_prepare};
    use crate::problem::{ProblemOptions, esm_problem};
    use crate::simulate::KeyMatch;
    use serde_json::{Value, json};
    use std::collections::HashMap;

    fn names(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    fn resolver(s: &Spelling, declared: &[String]) -> crate::simulate::KeyResolver {
        let names = declared.iter().map(String::as_str);
        s.resolver(names.clone(), names)
    }

    #[test]
    fn a_model_local_bare_key_reaches_every_name_it_ends() {
        let declared = names(&["k", "Leaf.k", "Other.k", "m"]);
        let r = resolver(&Spelling::ModelLocal("M".into()), &declared);
        let got = r.designates("k").unwrap();
        assert_eq!(
            got,
            vec![
                ("k".to_string(), KeyMatch::Exact),
                ("Leaf.k".to_string(), KeyMatch::Suffix),
                ("Other.k".to_string(), KeyMatch::Suffix)
            ]
        );
        assert_eq!(
            r.designates("M.Leaf.k").unwrap(),
            vec![("Leaf.k".to_string(), KeyMatch::ModelPrefixed)]
        );
        assert_eq!(r.strongest("k").unwrap().as_deref(), Some("k"));
    }

    #[test]
    fn a_qualified_key_designates_by_the_spec_rules() {
        let declared = names(&["A.k", "B.k", "A.m"]);
        let r = resolver(&Spelling::Qualified, &declared);
        let one = |k: &str| {
            r.designates(k)
                .unwrap()
                .into_iter()
                .map(|(n, _)| n)
                .collect::<Vec<_>>()
        };
        assert_eq!(one("m"), ["A.m"]);
        assert_eq!(one("A.k"), ["A.k"]);
        assert!(one("nothing").is_empty());
        let nested = names(&["P.sub.g", "Q.g"]);
        let rn = resolver(&Spelling::Qualified, &nested);
        assert_eq!(rn.designates("sub.g").unwrap()[0].0, "P.sub.g");
        // Rule 2: a leading segment that names a namespace is dropped; one
        // that names nothing is not.
        let rl = resolver(&Spelling::Qualified, &names(&["sub.k", "A.x"]));
        assert_eq!(rl.designates("A.sub.k").unwrap()[0].0, "sub.k");
        assert!(rl.designates("Typo.sub.k").unwrap().is_empty());
        match r.designates("k") {
            Err(crate::simulate::OverrideKeyError::Ambiguous { candidates, .. }) => {
                assert_eq!(candidates, ["A.k", "B.k"])
            }
            other => panic!("{other:?}"),
        }
        // Two keys for one variable collide; an exact key shadows the rest.
        assert!(r.canonical(["m", "A.m"]).unwrap()["A.m"] == "A.m");
        let rk = resolver(&Spelling::Qualified, &names(&["A.k", "A.sub.m"]));
        assert!(rk.canonical(["m", "sub.m"]).is_err());
    }

    fn model(rhs: f64) -> Value {
        json!({
            "variables": {"y": {"type": "unknown", "units": "1"}},
            "equations": [{"lhs": "y", "rhs": rhs}]
        })
    }

    fn doc(models: Value) -> Value {
        json!({"esm": "2.0.0", "metadata": {"name": "w"}, "models": models})
    }

    fn prepared_with(d: &Value, model_name: Option<&str>) -> super::PreparedBuild {
        let problem = crate::problem::ProblemOptions {
            model_name: model_name.map(str::to_string),
            ..Default::default()
        };
        let opts = BuildContext {
            problem: &problem,
            t0: 0.0,
            refuse_per_cell: false,
        };
        run_prepare(d, HashMap::new(), Vec::new(), &mut Vec::new(), &opts).unwrap()
    }

    /// The flattened system the pipeline hands forward is `flatten` of the
    /// document it loaded.
    fn assert_is_flatten_of(prepared: super::PreparedBuild, d: &Value) {
        let flat = prepared
            .flattened
            .expect("a flattened system handed forward");
        let again = crate::flatten::flatten(&crate::load_string(&d.to_string()).unwrap()).unwrap();
        assert_eq!(
            serde_json::to_value(&flat).unwrap(),
            serde_json::to_value(&again).unwrap()
        );
    }

    #[test]
    fn the_pipeline_hands_its_flattened_system_forward_when_it_is_the_documents() {
        let two = doc(json!({"A": model(1.0), "B": model(2.0)}));
        let prepared = prepared_with(&two, None);
        assert_eq!(prepared.model_name, None);
        assert_is_flatten_of(prepared, &two);

        // A document that is one model: built alone, it is the whole system.
        let one = doc(json!({"A": model(1.0)}));
        let prepared = prepared_with(&one, None);
        assert_eq!(prepared.model_name.as_deref(), Some("A"));
        assert_is_flatten_of(prepared, &one);

        // One model selected out of two is not the document's system.
        let prepared = prepared_with(&two, Some("A"));
        assert_eq!(prepared.model_name.as_deref(), Some("A"));
        assert!(prepared.flattened.is_none());
    }

    struct Column(Vec<f64>);

    impl crate::provider::DataProvider for Column {
        fn sample(&mut self) -> Result<ndarray::ArrayD<f64>, crate::provider::ProviderError> {
            Ok(
                ndarray::ArrayD::from_shape_vec(ndarray::IxDyn(&[self.0.len()]), self.0.clone())
                    .unwrap(),
            )
        }
    }

    /// A dynamic document whose derived set is invented from a provider's
    /// data: the compile sizes the set from the pipeline's value invention,
    /// which read that data, so a rate over the set compiles.
    #[test]
    fn the_compile_sizes_a_derived_set_from_the_pipelines_value_invention() {
        let key = json!({"op": "index", "args": ["code", "f"]});
        let d = json!({
            "esm": "2.0.0", "metadata": {"name": "Codes"},
            "index_sets": {
                "faces": {"kind": "interval", "size": 4},
                "kinds": {"kind": "derived", "from_faq": "kind_set"}
            },
            "data_sources": {"src": {"kind": "static",
                                     "source": {"url_template": "never-read.parquet"}}},
            "models": {"Codes": {
                "variables": {
                    "code": {"type": "parameter", "shape": ["faces"], "default": 0.0,
                             "update": {"kind": "data", "source": "src",
                                        "from": {"file_variable": "code"}}},
                    "kind_exists": {"type": "unknown", "shape": ["kinds"]},
                    "n": {"type": "unknown"},
                    "x": {"type": "unknown", "default": 0.0}
                },
                "equations": [
                    {"lhs": {"op": "index", "args": ["kind_exists", "k"]},
                     "rhs": {"op": "faq", "args": [], "id": "kind_set",
                             "semiring": "bool_and_or", "distinct": true,
                             "output_idx": ["k"], "ranges": {"f": {"from": "faces"}},
                             "key": key, "expr": {"op": "true", "args": []}}},
                    {"lhs": "n",
                     "rhs": {"op": "faq", "args": [], "semiring": "sum_product",
                             "output_idx": [], "ranges": {"k": {"from": "kinds"}},
                             "expr": 1.0}},
                    {"lhs": {"op": "D", "args": ["x"], "wrt": "t"}, "rhs": "n"}
                ]
            }}
        });
        let mut providers: HashMap<String, Box<dyn crate::provider::DataProvider>> = HashMap::new();
        providers.insert(
            "Codes.code".to_string(),
            Box::new(Column(vec![3.0, 1.0, 3.0, 2.0])),
        );
        let prob = esm_problem(
            &d,
            (0.0, 1.0),
            ProblemOptions {
                build_pipeline: true,
                providers,
                ..Default::default()
            },
        )
        .expect("the compile takes the pipeline's three members");
        assert_eq!(prob.extents().get("kind_set"), Some(&3));
        assert_eq!(prob.members()["kind_set"], vec![1, 2, 3]);
    }
}

#[cfg(test)]
mod in_effect_at_tests {
    use super::InEffectAt;
    use crate::provider::{DataProvider, ProviderError};
    use ndarray::{ArrayD, IxDyn};

    /// Records `0, 1, 2` from `0, 10, 20`; answers `None` while the record
    /// in effect has not changed since its last delivery.
    struct Steps {
        last: Option<usize>,
    }

    impl DataProvider for Steps {
        fn sample(&mut self) -> Result<ArrayD<f64>, ProviderError> {
            Ok(ArrayD::from_elem(IxDyn(&[]), 0.0))
        }

        fn refresh(&mut self, t: f64) -> Result<Option<ArrayD<f64>>, ProviderError> {
            match self.refresh_times().iter().rposition(|&b| b <= t) {
                Some(k) if self.last != Some(k) => {
                    self.last = Some(k);
                    Ok(Some(ArrayD::from_elem(IxDyn(&[]), k as f64)))
                }
                _ => Ok(None),
            }
        }

        fn refresh_times(&self) -> Vec<f64> {
            vec![0.0, 10.0, 20.0]
        }
    }

    fn at(t: f64) -> InEffectAt {
        InEffectAt {
            inner: Box::new(Steps { last: None }),
            t,
            feeds: "Q".to_string(),
            fallback: None,
            delivered: None,
        }
    }

    /// Every sample is the record in effect at `t`, not the provider's
    /// time-less one after the first.
    #[test]
    fn every_sample_is_the_record_in_effect() {
        let mut p = at(15.0);
        for _ in 0..3 {
            assert_eq!(p.sample().unwrap().first().copied(), Some(1.0));
        }
    }
}
