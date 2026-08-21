//! `prepare` — the build-time public surface of the Rust binding, mirroring
//! the Julia `prepare`/`observed_field` (simulate.jl) and the Python
//! `earthsci_ast.prepare` (Phase 4 of the clean consolidation).
//!
//! Runs everything deterministic-per-document ONCE — pushdown rewrite →
//! loader extent discovery → typed load → provider materialization →
//! build-time coordinate evaluation → value-invention → member-factor feedback
//! → gated pre-sliced fetch → dependency-ordered observed-graph evaluation —
//! and returns a [`Prepared`] whose [`Prepared::observed_field`] reads the
//! build-time fields back. This is the entry point the isrm.esm runner drives;
//! it never integrates.
//!
//! **Extent discovery** runs before the typed load because it CLOSES
//! metaparameters: a loader whose record count is only knowable after the
//! table is read declares `extent: {"metaparameter": "N_REC"}`, its providers
//! are sampled once up front (never twice), and the surviving length binds the
//! metaparameter every dependent index set is sized by. The caller no longer
//! counts rows and passes the number in — see
//! [`PrepareProvider::extent_metaparameter`].
//!
//! Those arrows are also [`PreparePhase`], and a host can watch them go by:
//! [`PrepareOptions::progress`] is the build-time counterpart of
//! [`crate::simulate::SimulateOptions::progress`], down to sharing its
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
//! * VI skolem/overlap factor observeds that are themselves join-free
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

use crate::aggregate::resolve_expr_ranges_with_extents;
use crate::parse::LoadOptions;
use crate::pushdown_rewrite::{
    GateAxis, ProviderGate, desugar_pushdown, pushdown_coupling_pairs, pushdown_provider_gates,
};
use crate::simulate_array::{
    ConstArrayScope, Value as EvalValue, eval_expression_with_extents_and_consts,
    run_value_invention,
};
use crate::types::{Expr, IndexSet, Model, VariableType};

/// What a [`PrepareOptions::progress`] observer wants [`prepare`] to do next —
/// the SAME type a [`crate::simulate::SimulateOptions::progress`] observer
/// returns.
///
/// Deliberately shared rather than mirrored: a host that already drives a solve
/// through [`Flow::Cancel`] should not have to learn a second cancellation
/// idiom to drive a build.
pub use crate::simulate::Flow;

/// A build-time preparation failure.
#[derive(Debug, Clone)]
pub struct PrepareError(pub String);

impl PrepareError {
    /// The prefix every observer-requested cancellation carries. Public so
    /// [`PrepareError::is_cancelled`] rests on a documented contract rather
    /// than a private convention.
    pub const CANCELLED_PREFIX: &'static str = "cancelled by the caller during";

    /// Whether this error is a [`PrepareOptions::progress`] observer's own
    /// [`Flow::Cancel`] rather than something going wrong — the counterpart of
    /// matching [`crate::simulate::SimulateError::Cancelled`].
    ///
    /// ## Why a message prefix and not a variant
    ///
    /// `PrepareError` is a public single-field tuple struct: an out-of-crate
    /// [`PrepareProvider`] constructs one as `PrepareError(msg)` and reads it
    /// back as `e.0` (the in-repo `esio_provider` bridge does both). Turning it
    /// into an enum, or adding a second field, breaks every one of them, while
    /// adding a field to `PrepareOptions` breaks none — so the source-compatible
    /// route wins, and the marker lives in the message, which is also the only
    /// place a host that merely logs the error would ever see it.
    ///
    /// ## A host still records WHY it cancelled
    ///
    /// This reports that a cancel happened, not what the observer wanted. A
    /// dispatcher distinguishing "the user pressed stop" from "the run hit its
    /// billing cap" must record that inside the observer, because only the
    /// observer knows — exactly as `earthscilab`'s `dispatch::solve` already
    /// does around `simulate`, where the two bill differently. The message
    /// names the phase and the item, so whichever it was, the stopping point is
    /// attributable rather than "somewhere in the last eight minutes".
    pub fn is_cancelled(&self) -> bool {
        self.0.starts_with(Self::CANCELLED_PREFIX)
    }
}

impl fmt::Display for PrepareError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "PrepareError: {}", self.0)
    }
}

impl std::error::Error for PrepareError {}

fn err(msg: impl Into<String>) -> PrepareError {
    PrepareError(msg.into())
}

/// One axis of the NEUTRAL per-axis selection handed to a gated provider —
/// the Rust spelling of the Python engine's `"all" | [0-based indices]` form.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AxisSel {
    /// The full native axis.
    All,
    /// The listed 0-based native indices, in order.
    Indices(Vec<usize>),
    /// The half-open strided range `[start, stop)` by `step` (`step >= 1`) —
    /// the contiguous form, kept whole rather than expanded to indices so a
    /// store-backed reader can push a slice down instead of a 52,411-long
    /// index list.
    Range {
        /// Inclusive first index (0-based).
        start: usize,
        /// Exclusive last index.
        stop: usize,
        /// Stride (>= 1).
        step: usize,
    },
}

impl AxisSel {
    /// The 0-based indices this selector picks over an axis of length
    /// `dim_len` (the engine-side fallback for a provider that cannot push a
    /// selection down).
    pub fn indices(&self, dim_len: usize) -> Vec<usize> {
        match self {
            AxisSel::All => (0..dim_len).collect(),
            AxisSel::Indices(v) => v.clone(),
            AxisSel::Range { start, stop, step } => {
                (*start..(*stop).min(dim_len)).step_by(*step).collect()
            }
        }
    }
}

/// The CONST data-provider contract [`prepare`] consumes: one provider feeds
/// ONE field (the `providers["<ModelPath>.<param>"]` convention shared with the
/// Julia/Python bindings). A gated provider may additionally honour a pushed-
/// down per-axis selection; one that cannot is fetched whole and sliced
/// engine-side (the fallback matches the pushdown result exactly).
pub trait PrepareProvider {
    /// CONST whole-field sample.
    fn sample(&mut self) -> Result<ArrayD<f64>, PrepareError>;

    /// Whether [`PrepareProvider::sample_with_selection`] pushes the selection
    /// down to the reader (fetching only what intersects it).
    fn supports_selection(&self) -> bool {
        false
    }

    /// Sample with a per-axis selection pushed down. EVERY requested axis is
    /// present in the result (a fixed axis comes back length-1 and is dropped
    /// by the engine).
    fn sample_with_selection(
        &mut self,
        _selection: &[AxisSel],
    ) -> Result<ArrayD<f64>, PrepareError> {
        Err(err("provider does not support selection pushdown"))
    }

    /// `false` for a DISCRETE provider (non-empty refresh times) — rejected by
    /// [`prepare`], which is build-time-only.
    fn is_const(&self) -> bool {
        true
    }

    /// A provider-declared gate (the fallback protocol mirroring Julia's
    /// `provider_gate_spec`); the record-derived gate takes precedence.
    fn gate_spec(&self) -> Option<ProviderGate> {
        None
    }

    /// The metaparameter this provider's own extent BINDS (esm-spec §8.9): a
    /// loader that discovers its record count at read time — an FF10 point
    /// inventory whose surviving-row count is not knowable until the table is
    /// decoded and filtered — declares `extent: {"metaparameter": "N_REC"}`,
    /// and [`prepare`] closes that metaparameter with the length of this
    /// provider's leading axis BEFORE the typed load, instead of the caller
    /// counting rows and passing the number in.
    ///
    /// Every provider naming the same metaparameter must agree, which is also
    /// the alignment check across a table's columns.
    fn extent_metaparameter(&self) -> Option<String> {
        None
    }
}

// --------------------------------------------------------------------------- //
// Progress observation.
// --------------------------------------------------------------------------- //

/// Which stage of the build [`prepare`] is in when it reports.
///
/// These are the document-independent stages of [`prepare`]'s own pipeline, in
/// the order it runs them, and they are exactly the stages
/// [`PrepareOptions::verbose`] already narrates — the observer did not invent a
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
    /// [`PrepareOptions::gated_fetch_batch`] splits it further.
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

/// How far along an in-flight [`prepare`] is, handed to
/// [`PrepareOptions::progress`] at every phase boundary AND at every unit of
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

/// A build progress observer. See [`PrepareOptions::progress`].
///
/// Unconditionally `Send + Sync`, unlike [`crate::simulate::ProgressFn`], which
/// drops the bound on `wasm32` for a `js_sys::Function` observer: the whole
/// `prepare` module is `#[cfg(not(target_arch = "wasm32"))]`, so there is no
/// wasm host to accommodate and no reason to make native callers pay for one.
pub type PrepareProgressFn = Arc<dyn Fn(&PrepareProgress<'_>) -> Flow + Send + Sync>;

/// Build-time options for [`prepare`].
#[derive(Clone, Default)]
pub struct PrepareOptions {
    /// Select one model when the document holds several.
    pub model_name: Option<String>,
    /// Metaparameter bindings closed at load (esm-spec §9.7.6 site 4).
    pub metaparameters: BTreeMap<String, i64>,
    /// Base path anchoring relative `{ref}`s.
    pub base_path: Option<PathBuf>,
    /// Opt in to the automatic projection-pushdown desugar.
    pub pushdown_rewrite: bool,
    /// Scalar parameter overrides (exact or bare names), baked into the build.
    pub parameters: HashMap<String, f64>,
    /// Per-step progress lines on stdout.
    ///
    /// This is the built-in observer: it prints at the same points
    /// [`PrepareOptions::progress`] is called, and the two are independent —
    /// setting both prints and observes.
    pub verbose: bool,

    /// If `Some`, called at every phase boundary and at every unit of work
    /// inside [`PreparePhase::GatedFetch`] and [`PreparePhase::Observeds`].
    /// Returning [`Flow::Cancel`] abandons the build with a [`PrepareError`]
    /// for which [`PrepareError::is_cancelled`] is true.
    ///
    /// **Called unthrottled, deliberately**, for the same reason
    /// [`crate::simulate::SimulateOptions::progress`] is: `prepare` has no
    /// portable clock to throttle against, and rate limiting therefore belongs
    /// to the host, which does. Keep the observer cheap — a document with
    /// hundreds of observeds reports hundreds of times in a build that may take
    /// milliseconds.
    ///
    /// ## What this is for
    ///
    /// A dispatched static evaluation — a document with no ODEs, which
    /// `simulate` never touches — is otherwise a black box for as long as it
    /// runs: no progress, no cancel, and no way for a caller to enforce a
    /// resource cap except by killing the process. A watchdog thread is not a
    /// substitute: it stops at an arbitrary point with no attributable elapsed
    /// time, and cannot interrupt a single long fetch at all. Going through the
    /// observer means the stopping point is a named phase and a named item.
    pub progress: Option<PrepareProgressFn>,

    /// Split a gated provider's pre-sliced fetch into requests of at most this
    /// many native indices along the gated axis.
    ///
    /// `None` (the default) issues ONE request per gated provider, exactly as
    /// before this option existed. That is the right default and also the
    /// reason this option exists: one request is one
    /// [`PreparePhase::GatedFetch`] report, and on the InMAP ISRM document that
    /// single request is 15–25 GB over the network and the longest thing the
    /// build does. A host that wants a moving bar — or a cancel that lands in
    /// under several minutes — sets this and gets one report per batch instead.
    ///
    /// The result is IDENTICAL either way: the gated axis' index list is split
    /// into contiguous runs and the pieces are written back in order into one
    /// pre-allocated slab, so nothing is reordered and nothing is copied twice.
    /// The cost of a small batch is at the seams — a chunked store re-reads the
    /// chunk straddling each boundary, so `batches - 1` extra chunk reads —
    /// which is why the library does not pick a size on the caller's behalf.
    pub gated_fetch_batch: Option<usize>,
}

// Hand-written because `PrepareProgressFn` is a trait object: it cannot derive
// `Debug`, and a `PrepareOptions` that no longer prints would be a regression
// for every existing `{:?}` on a build error path. Mirrors the same treatment
// `SimulateOptions` needed when it grew an observer.
impl fmt::Debug for PrepareOptions {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("PrepareOptions")
            .field("model_name", &self.model_name)
            .field("metaparameters", &self.metaparameters)
            .field("base_path", &self.base_path)
            .field("pushdown_rewrite", &self.pushdown_rewrite)
            .field("parameters", &self.parameters)
            .field("verbose", &self.verbose)
            .field(
                "progress",
                &self
                    .progress
                    .as_ref()
                    .map(|_| "<observer>")
                    .unwrap_or("None"),
            )
            .field("gated_fetch_batch", &self.gated_fetch_batch)
            .finish()
    }
}

/// The product of [`prepare`]: every build-time-evaluable observed of the
/// prepared document, materialized through the document's own graph, plus the
/// value-invention products the contract record reports.
pub struct Prepared {
    /// The (possibly rewritten) raw document.
    pub doc: JsonValue,
    /// The prepared model's name.
    pub model_name: String,
    /// Observed name → build-time field (dependency-complete).
    pub fields: HashMap<String, ArrayD<f64>>,
    /// Value-invention producer id (`from_faq`) → sorted-distinct member ids.
    pub members: HashMap<String, Vec<i64>>,
    /// Value-invention producer id → derived index-set extent.
    pub extents: HashMap<String, i64>,
    /// Provider keys that were deferred + fetched pre-sliced (sorted).
    pub gated_provider_keys: Vec<String>,
}

impl Prepared {
    /// The build-time field of observed `name` (exact, else the unique
    /// dotted-name tail match), or an error when `name` was not evaluated.
    pub fn observed_field(&self, name: &str) -> Result<&ArrayD<f64>, PrepareError> {
        if let Some(a) = self.fields.get(name) {
            return Ok(a);
        }
        if !name.contains('.') {
            let mut matches: Vec<&String> = self
                .fields
                .keys()
                .filter(|k| k.contains('.') && k.rsplit('.').next() == Some(name))
                .collect();
            matches.sort();
            if let Some(k) = matches.first() {
                return Ok(&self.fields[*k]);
            }
        }
        Err(err(format!(
            "observed_field: '{name}' is not a build-time-evaluable observed of the \
             prepared document"
        )))
    }
}

// --------------------------------------------------------------------------- //
// Dependency order over the observeds (shared with the pushdown-era runner).
// --------------------------------------------------------------------------- //

/// The factor names an expression declares it reads (`aggregate.args` plus
/// every gather / bare reference), gathered recursively. The dependency edges
/// come from the MODEL, not from a re-derivation here.
fn declared_args(expr: &Expr, out: &mut HashSet<String>) {
    match expr {
        Expr::Variable(name) => {
            out.insert(name.clone());
        }
        Expr::Operator(node) => {
            for a in &node.args {
                declared_args(a, out);
            }
            node.for_each_child(&mut |c| declared_args(c, out));
        }
        _ => {}
    }
}

/// Dependency order over observed definitions: an observed follows every
/// observed it names. A cycle is a malformed model and is a hard error.
fn observed_order(defs: &HashMap<String, Expr>) -> Result<Vec<String>, PrepareError> {
    let deps: HashMap<String, HashSet<String>> = defs
        .iter()
        .map(|(n, e)| {
            let mut a = HashSet::new();
            declared_args(e, &mut a);
            a.retain(|x| defs.contains_key(x) && x != n);
            (n.clone(), a)
        })
        .collect();

    let mut ordered = Vec::new();
    let mut done: HashSet<String> = HashSet::new();
    let mut pending: HashSet<String> = defs.keys().cloned().collect();
    while !pending.is_empty() {
        let mut ready: Vec<String> = pending
            .iter()
            .filter(|n| deps[*n].iter().all(|d| done.contains(d)))
            .cloned()
            .collect();
        if ready.is_empty() {
            let mut rest: Vec<_> = pending.into_iter().collect();
            rest.sort();
            return Err(err(format!("cyclic observed dependency among {rest:?}")));
        }
        ready.sort(); // deterministic tie-break
        for n in ready {
            ordered.push(n.clone());
            done.insert(n.clone());
            pending.remove(&n);
        }
    }
    Ok(ordered)
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
        .filter(|(_, def)| {
            serde_json::to_value(def)
                .is_ok_and(|raw| !crate::value_invention::is_value_invention_assignment(&raw))
        })
        .collect()
}

/// Every declared 0-D parameter's default (overridden by `overrides`, exact or
/// bare key) — the scalar evaluation scope, sorted by name.
fn scalar_params(model: &Model, overrides: &HashMap<String, f64>) -> (Vec<f64>, Vec<String>) {
    let mut names: Vec<String> = model
        .variables
        .iter()
        .filter(|(_, v)| {
            v.var_type == VariableType::Parameter
                && v.shape.as_ref().map(|s| s.is_empty()).unwrap_or(true)
                && v.default.is_some()
        })
        .map(|(k, _)| k.clone())
        .collect();
    names.sort();
    let vals = names
        .iter()
        .map(|n| {
            overrides
                .get(n)
                .or_else(|| overrides.get(n.rsplit('.').next().unwrap_or(n)))
                .copied()
                .unwrap_or_else(|| model.variables[n].default.unwrap_or(0.0))
        })
        .collect();
    (vals, names)
}

// --------------------------------------------------------------------------- //
// Pushdown-path name aliasing (the Python `_inject_pushdown_aliases`, adapted
// to the UN-flattened Rust model scope: the coupling routes loader keys onto
// namespaced model names, and every dotted key additionally surfaces under its
// unique shallowest bare tail — the spelling the authored expressions use).
// --------------------------------------------------------------------------- //
fn inject_aliases(arrays: &mut HashMap<String, ArrayD<f64>>, coupling: &[(String, String)]) {
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
    defs: &HashMap<String, Expr>,
    join_free: &HashSet<String>,
) -> HashSet<String> {
    let mut needed: HashSet<String> = HashSet::new();
    let mut frontier: Vec<String> = Vec::new();
    let mut refs = HashSet::new();
    for s in seeds {
        declared_args(s, &mut refs);
    }
    for r in refs {
        if join_free.contains(&r) && needed.insert(r.clone()) {
            frontier.push(r);
        }
    }
    while let Some(cur) = frontier.pop() {
        let mut refs = HashSet::new();
        declared_args(&defs[&cur], &mut refs);
        for r in refs {
            if join_free.contains(&r) && needed.insert(r.clone()) {
                frontier.push(r);
            }
        }
    }
    needed
}

/// Evaluate one observed through the full evaluator; returns the dense field.
#[allow(clippy::too_many_arguments)]
fn eval_observed(
    name: &str,
    def: &Expr,
    arrays: &HashMap<String, ArrayD<f64>>,
    param_vals: &[f64],
    param_names: &[String],
    index_sets: &HashMap<String, IndexSet>,
    extents: &HashMap<String, i64>,
    const_arrays: &ConstArrayScope,
) -> Result<ArrayD<f64>, PrepareError> {
    let mut expr = def.clone();
    resolve_expr_ranges_with_extents(&mut expr, index_sets, extents)
        .map_err(|e| err(format!("resolve ranges for {name}: {e}")))?;
    let val = eval_expression_with_extents_and_consts(
        &expr,
        arrays,
        param_vals,
        param_names,
        0.0,
        extents,
        const_arrays,
    )
    .map_err(|e| err(format!("evaluate {name}: {e}")))?;
    Ok(match val {
        EvalValue::Array(a) => *a,
        EvalValue::Scalar(s) => ArrayD::from_elem(IxDyn(&[1]), s),
    })
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
) -> Result<GatedFetchPlan, PrepareError> {
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

/// Run a gate's plan, reporting through `report` and honouring a cancel.
///
/// One request, unless `batch` splits the gated axis' index list into contiguous
/// runs — in which case the pieces are assembled into ONE pre-allocated slab in
/// request order, which is bit-identical to the single-request result because
/// nothing is reordered and the concatenation seam is a plain copy. Assembling
/// in place rather than via `ndarray::concatenate` matters at this size: the SR
/// slabs are hundreds of MB, and holding every piece plus their concatenation
/// would peak at twice the answer instead of the answer plus one batch.
/// [`prepare`]'s internal observation sink, erased so a helper can report
/// without knowing whether an observer is attached or what it captured.
type ReportFn<'a> =
    dyn FnMut(PreparePhase, usize, Option<usize>, &str) -> Result<(), PrepareError> + 'a;

#[allow(clippy::too_many_arguments)]
fn run_gated_fetch(
    key: &str,
    prov: &mut dyn PrepareProvider,
    plan: &GatedFetchPlan,
    batch: Option<usize>,
    issued: &mut usize,
    total_requests: usize,
    report: &mut ReportFn<'_>,
) -> Result<ArrayD<f64>, PrepareError> {
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
) -> Result<ArrayD<f64>, PrepareError> {
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

/// Prepare `doc` (a raw parsed `.esm` document) once: run the pushdown rewrite
/// (when opted in), materialize CONST providers, evaluate the build-time
/// coordinates, run value-invention, feed the member factor back, fetch the
/// gated providers pre-sliced, and evaluate the whole observed graph in
/// dependency order. Returns the [`Prepared`] artifact.
///
/// `providers` maps the CONSUMING PARAMETER's namespaced name
/// (`"<ModelPath>.<param>"`) to a CONST [`PrepareProvider`]; an entry the
/// rewrite record's gate routes onto a gated array is DEFERRED and fetched
/// pre-sliced after value-invention. From esm 1.0.0 a data source declares no
/// variables, so the consuming parameter is the only spelling that names one
/// field and every field: two parameters may read one `file_variable`
/// differently, and two models may declare the same parameter name against one
/// source. `const_arrays` are the caller-supplied build-time factor arrays
/// (keyed by model-local or `<Source>.<file_variable>` names — the routing
/// aliasing surfaces both spellings).
///
/// # Watching a long build
///
/// A build over real data is not fast: on the InMAP ISRM the gated fetch alone
/// is tens of gigabytes and the whole `prepare` runs for the better part of a
/// quarter of an hour. [`PrepareOptions::progress`] observes it as it goes —
/// per gated request and per observed, not merely per phase — and returning
/// [`Flow::Cancel`] stops it at a named point. Pair it with
/// [`PrepareOptions::gated_fetch_batch`] so the fetch itself is interruptible.
pub fn prepare(
    doc: &JsonValue,
    const_arrays: HashMap<String, ArrayD<f64>>,
    providers: Vec<(String, Box<dyn PrepareProvider>)>,
    opts: &PrepareOptions,
) -> Result<Prepared, PrepareError> {
    let log = |msg: &str| {
        if opts.verbose {
            println!("{msg}");
        }
    };

    // The observation point. Every phase boundary and every countable unit of
    // work inside the two phases that dominate a large build goes through here,
    // so the phase structure `verbose` narrates and the phase structure a host
    // observes cannot drift — there is only one.
    //
    // Returns `Err` on `Flow::Cancel`, which unwinds `prepare` through the `?`
    // it is already threaded on. The message names the phase and the item, so a
    // cancel is attributable to a point in the build rather than to a wall
    // clock the library does not have.
    let mut report = |phase: PreparePhase,
                      done: usize,
                      total: Option<usize>,
                      item: &str|
     -> Result<(), PrepareError> {
        let Some(cb) = &opts.progress else {
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
            Flow::Cancel => Err(err(format!(
                "{} {phase}{}",
                PrepareError::CANCELLED_PREFIX,
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
            ))),
        }
    };

    // ---- Phase-1 semantics: pushdown prepass BEFORE the typed parse ---------
    report(PreparePhase::Rewrite, 0, None, "")?;
    let rewritten = if opts.pushdown_rewrite {
        desugar_pushdown(doc, opts.model_name.as_deref()).map_err(|e| err(e.0))?
    } else {
        std::borrow::Cow::Borrowed(doc)
    };
    let rewrite_fired = matches!(rewritten, std::borrow::Cow::Owned(_));
    let provider_keys: Vec<String> = providers.iter().map(|(k, _)| k.clone()).collect();
    let pd_gates: HashMap<String, ProviderGate> = if rewrite_fired {
        pushdown_provider_gates(&rewritten, &provider_keys).map_err(|e| err(e.0))?
    } else {
        HashMap::new()
    };
    let pd_coupling = pushdown_coupling_pairs(&rewritten);
    log(&format!(
        "  [prepare] pushdown rewrite {}",
        if rewrite_fired {
            "fired"
        } else {
            "did not fire"
        }
    ));

    // ---- extent discovery: a loader that measures its OWN record count ------
    // Must run BEFORE the typed load, because a discovered extent binds a
    // metaparameter and metaparameters are closed at the loader API (§9.7.6
    // site 4). A gated provider is skipped: its extent is the value-invention
    // set's, which does not exist yet.
    let mut providers = providers;
    let mut discovered: HashMap<String, ArrayD<f64>> = HashMap::new();
    let mut metaparameters = opts.metaparameters.clone();
    let mut discovered_by: BTreeMap<String, (i64, String)> = BTreeMap::new();
    for (key, prov) in providers.iter_mut() {
        let Some(mp) = prov.extent_metaparameter() else {
            continue;
        };
        if pd_gates.contains_key(key) || prov.gate_spec().is_some() {
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
        log(&format!("  [prepare] extent {mp} <- {key} = {n}"));
        discovered_by.insert(mp.clone(), (n, key.clone()));
        metaparameters.insert(mp, n);
        discovered.insert(key.clone(), a);
    }

    // ---- typed load (metaparameters closed at the loader API) ---------------
    report(PreparePhase::Load, 0, None, "")?;
    let text = serde_json::to_string(rewritten.as_ref())
        .map_err(|e| err(format!("serialize rewritten document: {e}")))?;
    let load_opts = LoadOptions {
        base_path: opts.base_path.clone(),
        metaparameters,
    };
    let file = crate::parse::load_with_options(&text, &load_opts)
        .map_err(|e| err(format!("load rewritten document: {e}")))?;
    let index_sets: HashMap<String, IndexSet> = file.index_sets.clone().unwrap_or_default();
    let models = file
        .models
        .as_ref()
        .ok_or_else(|| err("document has no models"))?;
    let model_name = match &opts.model_name {
        Some(n) => n.clone(),
        None if models.len() == 1 => models.keys().next().unwrap().clone(),
        None => return Err(err("document holds several models; pass model_name")),
    };
    let model = models
        .get(&model_name)
        .ok_or_else(|| err(format!("model '{model_name}' not found in the document")))?
        .clone();

    let (param_vals, param_names) = scalar_params(&model, &opts.parameters);

    // ---- provider injection: eager CONST materialization; gated deferral ----
    let mut arrays: HashMap<String, ArrayD<f64>> = const_arrays;
    let mut gated: Vec<(String, Box<dyn PrepareProvider>, ProviderGate)> = Vec::new();
    let n_providers = providers.len();
    for (i, (k, mut prov)) in providers.into_iter().enumerate() {
        report(
            PreparePhase::ConstProviders,
            i,
            Some(n_providers),
            k.as_str(),
        )?;
        if let Some(a) = discovered.remove(&k) {
            // Already materialized by the extent-discovery pre-pass; never
            // sampled twice.
            arrays.insert(k, a);
        } else if let Some(gate) = pd_gates.get(&k) {
            // Record-derived gate (the rewrite's own metadata.x_esd.pushdown):
            // defer — value-invention must derive the gating set's members
            // before the rows to fetch are known.
            gated.push((k, prov, gate.clone()));
        } else if let Some(gate) = prov.gate_spec() {
            // Provider-declared gate (the fallback protocol) — also deferred.
            gated.push((k, prov, gate));
        } else if !prov.is_const() {
            return Err(err(format!(
                "prepare: provider '{k}' is DISCRETE (non-empty refresh times); \
                 prepare() is build-time-only"
            )));
        } else {
            let a = prov
                .sample()
                .map_err(|e| err(format!("materialize const provider '{k}': {}", e.0)))?;
            log(&format!(
                "  [prepare] const provider {k} -> {:?}",
                a.shape()
            ));
            arrays.insert(k, a);
        }
    }
    report(
        PreparePhase::ConstProviders,
        n_providers,
        Some(n_providers),
        "",
    )?;
    let mut gated_keys: Vec<String> = gated.iter().map(|(k, _, _)| k.clone()).collect();
    gated_keys.sort();

    // ---- pushdown-path name aliasing ----------------------------------------
    if opts.pushdown_rewrite {
        inject_aliases(&mut arrays, &pd_coupling);
    }

    // ---- the CONST-ARRAY registry (CONFORMANCE_SPEC §5.5.5) -----------------
    // Everything in `arrays` at THIS point is build-time factor data: the
    // caller's `const_arrays`, the materialized const providers, and the
    // pushdown coupling aliases. That is exactly the Julia reference's
    // `const_arrays` registry, so a gather on one of these names is a
    // CONST-ARRAY gather — an out-of-range index raises
    // `E_TREEWALK_CONSTARRAY_OOB` rather than silently reading the state
    // gather's zero ghost, which §5.5.5 says is never a const array's. The
    // observeds this function evaluates below are inserted into `arrays` as it
    // goes and are deliberately NOT in the registry: they are observed gathers
    // and keep the zero-ghost convention.
    let const_scope = ConstArrayScope::from_names(arrays.keys().cloned());

    // ---- observed definitions + the join-free partition ---------------------
    // Resolve each OVERLAP gate's two range symbols while the ranges still
    // carry their `{ "from": <index set> }` linkage (`eval_observed` resolves
    // ranges on its own clone, which erases it). Without this the dense
    // evaluator cannot tell which loop symbol each envelope side runs over and
    // declines to let the gate drive — correct, but back at `O(∏ranges)`.
    // Infallible: an unresolvable gate simply stays undriven.
    let mut defs = observed_defs(&model);
    {
        let var_shapes = crate::join::declared_var_shapes(&model);
        for e in defs.values_mut() {
            crate::join::resolve_overlap_syms_expr(e, &var_shapes);
        }
    }
    let defs = defs;
    let join_free: HashSet<String> = defs
        .iter()
        .filter(|(_, e)| match e {
            Expr::Operator(node) => node.join.as_ref().map(|j| j.is_empty()).unwrap_or(true),
            _ => true,
        })
        .map(|(n, _)| n.clone())
        .collect();
    let order = observed_order(&defs)?;

    // ---- build-time coordinate path: producer-seeded join-free closure ------
    // (the Rust analogue of Julia's `_derive_binning_coords` general-eval
    // seeding; tolerant — an unresolved coordinate degrades to the engine's
    // own fail-closed contract downstream, exactly as in Python.)
    let seeds: Vec<&Expr> = model
        .equations
        .iter()
        .filter_map(|eq| match &eq.rhs {
            Expr::Operator(node)
                if matches!(node.op.as_str(), "aggregate" | "arrayop")
                    && node.distinct == Some(true)
                    && node.join.as_ref().map(|j| !j.is_empty()).unwrap_or(false) =>
            {
                Some(&eq.rhs)
            }
            _ => None,
        })
        .collect();
    let mut fields: HashMap<String, ArrayD<f64>> = HashMap::new();
    if !seeds.is_empty() {
        let needed = producer_seed_closure(&seeds, &defs, &join_free);
        let no_extents: HashMap<String, i64> = HashMap::new();
        let coords: Vec<&String> = order.iter().filter(|n| needed.contains(*n)).collect();
        let n_coords = coords.len();
        for (i, name) in coords.into_iter().enumerate() {
            report(PreparePhase::Coordinates, i, Some(n_coords), name.as_str())?;
            match eval_observed(
                name,
                &defs[name],
                &arrays,
                &param_vals,
                &param_names,
                &index_sets,
                &no_extents,
                &const_scope,
            ) {
                Ok(a) => {
                    log(&format!(
                        "  [prepare] build-time coordinate {name} -> {:?}",
                        a.shape()
                    ));
                    arrays.insert(name.clone(), a.clone());
                    fields.insert(name.clone(), a);
                }
                Err(e) => {
                    // Tolerant (mirrors Python's skip_unresolved=True): the
                    // producer then fails with ITS diagnostic if it truly
                    // needed this coordinate.
                    log(&format!(
                        "  [prepare] build-time coordinate {name} skipped ({})",
                        e.0
                    ));
                }
            }
        }
        report(PreparePhase::Coordinates, n_coords, Some(n_coords), "")?;
    }

    // ---- VALUE INVENTION: the graph derives its own support set -------------
    report(PreparePhase::ValueInvention, 0, None, "")?;
    let vi = run_value_invention(&model, &index_sets, Some(&arrays))
        .map_err(|e| err(format!("value invention: {e}")))?;
    let mut members: HashMap<String, Vec<i64>> = HashMap::new();
    for (faq, mem) in &vi.members {
        let ids: Vec<i64> = mem
            .iter()
            .map(|k| match k {
                crate::relational::Key::Int(i) => Ok(*i),
                other => Err(err(format!(
                    "faq '{faq}': expected scalar integer member keys, got {other:?}"
                ))),
            })
            .collect::<Result<_, _>>()?;
        members.insert(faq.clone(), ids);
    }
    let extents = vi.extents.clone();

    // ---- Hook 1: derived-set member ids fed back as the member_factor -------
    // Collected and SORTED first, so both the observed event stream and the
    // verbose narration are deterministic; `index_sets` is a `HashMap` and
    // iterating it directly made the order vary run to run.
    let mut mf_sets: Vec<(&String, &String, &Vec<i64>)> = index_sets
        .iter()
        .filter(|(_, is)| is.kind == "derived")
        .filter_map(|(sname, is)| {
            let (mf, faq) = (is.member_factor.as_ref()?, is.from_faq.as_ref()?);
            Some((sname, mf, members.get(faq)?))
        })
        .collect();
    mf_sets.sort_by(|a, b| a.0.cmp(b.0));
    let n_mf = mf_sets.len();
    for (i, (sname, mf, mem)) in mf_sets.into_iter().enumerate() {
        report(PreparePhase::MemberFactors, i, Some(n_mf), mf.as_str())?;
        let v: Vec<f64> = mem.iter().map(|&m| m as f64).collect();
        log(&format!(
            "  [prepare] member_factor {mf} <- |{sname}| = {}",
            v.len()
        ));
        let arr = ArrayD::from_shape_vec(IxDyn(&[v.len()]), v)
            .map_err(|e| err(format!("member factor '{mf}': {e}")))?;
        arrays.insert(mf.clone(), arr);
    }
    report(PreparePhase::MemberFactors, n_mf, Some(n_mf), "")?;

    // ---- Hook 2: gated-provider deferral → post-VI pre-sliced fetch ---------
    // Every gate is PLANNED before any of it is issued, so the phase reports one
    // running "request i of N" across all providers rather than restarting the
    // count at each one. Planning is pure bookkeeping over the invented members
    // — it reads nothing and costs nothing next to the fetch it describes.
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
        let mut plan = gated_fetch_plan(key, gate, &index_sets, &members, &extents)?;
        plan.n_requests = if prov.supports_selection() {
            match &plan.selection[plan.gated_pos] {
                AxisSel::Indices(idx) => idx
                    .len()
                    .div_ceil(opts.gated_fetch_batch.unwrap_or(usize::MAX).max(1))
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

    for ((key, mut prov, gate), plan) in gated.into_iter().zip(plans) {
        let arr = run_gated_fetch(
            &key,
            prov.as_mut(),
            &plan,
            opts.gated_fetch_batch,
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
        // Surface the compact slab under the MODEL variable this provider feeds
        // (its local tail — the authored spelling the un-flattened expressions
        // use). From esm 1.0.0 the key IS that variable's namespaced name, so it
        // answers on the routing's `to` side; the `frm` side still answers for a
        // provider registered under the SOURCE's spelling, and the gate's tail is
        // the last resort.
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
        let target = pd_coupling
            .iter()
            .find(|(frm, to)| frm == &key || to == &key)
            .map(|(_, to)| to.rsplit('.').next().unwrap_or(to).to_string())
            .unwrap_or_else(|| gate.applies_to[0].clone());
        log(&format!(
            "  [prepare] gated fetch {key} -> {target} {:?}",
            arr.shape()
        ));
        arrays.insert(target, arr);
    }
    report(
        PreparePhase::GatedFetch,
        total_requests,
        Some(total_requests),
        "",
    )?;

    // ---- evaluate the whole observed graph in dependency order --------------
    // Every observed that still needs evaluating, counted up front: `order`
    // includes the coordinate pre-pass's products, and a `total` that a `continue`
    // silently makes unreachable is a bar that never fills.
    let pending: Vec<&String> = order.iter().filter(|n| !fields.contains_key(*n)).collect();
    let n_pending = pending.len();
    for (i, name) in pending.into_iter().enumerate() {
        report(PreparePhase::Observeds, i, Some(n_pending), name.as_str())?;
        let t = std::time::Instant::now();
        let a = eval_observed(
            name,
            &defs[name],
            &arrays,
            &param_vals,
            &param_names,
            &index_sets,
            &extents,
            &const_scope,
        )?;
        log(&format!(
            "  [prepare] {name:<24} shape={:?}  {:>7.1} s",
            a.shape(),
            t.elapsed().as_secs_f64()
        ));
        arrays.insert(name.clone(), a.clone());
        fields.insert(name.clone(), a);
    }
    report(PreparePhase::Observeds, n_pending, Some(n_pending), "")?;

    Ok(Prepared {
        doc: rewritten.into_owned(),
        model_name,
        fields,
        members,
        extents,
        gated_provider_keys: gated_keys,
    })
}
