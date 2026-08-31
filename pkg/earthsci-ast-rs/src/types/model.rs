use super::*;
use indexmap::IndexMap;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// A document-scoped index set declared in a model's `index_sets` registry
/// (RFC semiring-faq-unified-ir §5.2 / §8). Unifies ESM `domain.spatial` grid
/// dims and ESI categorical index sets under one shape. `kind` selects which
/// optional fields are meaningful (enforced by the schema's kind-conditional
/// `allOf`):
/// - `interval`    → `size`
/// - `categorical` → `members`
/// - `derived`     → `from_faq`
/// - `ragged`      → `of`, `offsets`, `values`
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct IndexSet {
    /// `"interval" | "categorical" | "derived" | "ragged"`.
    pub kind: String,

    /// Dense size for `kind: "interval"`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub size: Option<i64>,

    /// Enumerated members for `kind: "categorical"`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub members: Option<Vec<serde_json::Value>>,

    /// Source FAQ-node id for `kind: "derived"`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from_faq: Option<String>,

    /// Members-fed-back-as-const-factor for `kind: "derived"` (projection-
    /// pushdown Phase 2b Hook 1, CONFORMANCE_SPEC §5.5.6).
    ///
    /// Names a model `parameter` const factor that the build fills with this
    /// set's materialized value-invention MEMBERS — the invented 1-based
    /// full-grid ids, `vi.members[from_faq]` — so an in-model gather
    /// `index(W, index(<member_factor>, c))` can pull the full-grid rows the
    /// compact derived axis selects. There is no `member(set, c)` IR op; this
    /// feedback IS the mechanism.
    ///
    /// `None` for every non-feedback set, so ordinary sets round-trip
    /// byte-identically. Mirrors the Julia reference's `IndexSet.member_factor`
    /// and the `member_factor` property of esm-schema.json. Without it the Rust
    /// binding silently DROPPED a normative field on parse, so a parse→emit
    /// round-trip of an overlap-gated document (the shared
    /// `overlap_gate_point_in_rect.esm` fixture among them) lost it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub member_factor: Option<String>,

    /// Parent index sets for `kind: "ragged"`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub of: Option<Vec<String>>,

    /// CSR/length backing-factor name for `kind: "ragged"`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub offsets: Option<String>,

    /// Member backing-factor name for `kind: "ragged"`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub values: Option<String>,
}

/// One entry of the document-scoped [`EsmFile::coordinates`] registry
/// (RFC streaming-output-sinks §8.3): marks an existing data array — or an
/// inline literal vector — as a physical coordinate and attaches CF metadata.
///
/// Exactly one of `source` and `values` is present. The coordinate's shape
/// comes from its source, so it is NOT attached to any single axis: that one
/// rule covers rectilinear (1-D monotonic → CF *dimension* coordinate),
/// unstructured (1-D over a shared dimension) and curvilinear (2-D `lat(y,x)`)
/// grids, the latter two emitting CF *auxiliary* coordinates.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Coordinate {
    /// Name of an existing data array (model variable, parameter, or loader
    /// field) supplying this coordinate's values. Mutually exclusive with
    /// `values`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,

    /// Inline literal 1-D coordinate vector for the simple rectilinear case,
    /// mirroring [`FunctionTableAxis::values`]. Mutually exclusive with
    /// `source`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub values: Option<Vec<f64>>,

    /// CF standard name (e.g. `"latitude"`), emitted verbatim.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub standard_name: Option<String>,

    /// CF/UDUNITS units string (e.g. `"degrees_north"`). Advisory at load
    /// time, matching [`FunctionTableAxis::units`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub units: Option<String>,

    /// CF axis role (`"X"` / `"Y"` / `"Z"` / `"T"`) for a 1-D monotonic
    /// dimension coordinate; absent for auxiliary coordinates, which have no
    /// single axis.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub axis: Option<String>,
}

/// ODE-based model component
///
/// # `name` / `description` are NOT schema keys
///
/// The schema's `Model` is `additionalProperties: false` and declares neither
/// `name` (a model's name is its key in the `models` map) nor `description`.
/// Both fields below are therefore schema-INVALID the moment they are set, and
/// `save()` will happily emit a document that fails its own schema. They are
/// harmless only while they stay `None`, which is what every load-parsed model
/// leaves them as — no deserializer ever fills them, because the wire form has
/// no such keys.
///
/// They are not dead, though: [`crate::update_model_metadata`] — a tier-
/// `extension`, Rust-only entry in `api-surface.json` — sets both, so its ONLY
/// observable effect is to make a valid document invalid. `graph.rs` also reads
/// `name` for a component-node label, where it is always `None` in practice.
/// Left in place deliberately rather than removed: deleting them changes a
/// published API surface, which is a decision for whoever owns that surface,
/// not a drive-by fix. Do not start populating them.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Model {
    /// Human-readable model name. NOT a schema key — see the type-level note.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,

    /// Academic citation or data source reference
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reference: Option<Reference>,

    /// State variables, parameters, and observed quantities (keyed by name)
    pub variables: IndexMap<String, ModelVariable>,

    /// Differential equations
    pub equations: Vec<Equation>,

    /// Discrete events
    #[serde(skip_serializing_if = "Option::is_none")]
    pub discrete_events: Option<Vec<DiscreteEvent>>,

    /// Continuous events
    #[serde(skip_serializing_if = "Option::is_none")]
    pub continuous_events: Option<Vec<ContinuousEvent>>,

    /// Named child models (subsystems), keyed by unique identifier
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subsystems: Option<IndexMap<String, serde_json::Value>>,

    /// Brief description. NOT a schema key — see the type-level note.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,

    /// Model-level default numerical tolerance for inline tests.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tolerance: Option<Tolerance>,

    /// Inline validation tests that exercise this model in isolation.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tests: Option<Vec<ModelTest>>,

    /// Inline illustrative analyses of how to run this model (schema
    /// `Model.analyses`); previously unmodelled here and so dropped on
    /// round trip.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub analyses: Option<Vec<ModelAnalysis>>,

    /// Equations that hold only at t=0 (initialization-only, not time-stepped).
    /// Introduced for aerosol equilibrium / plume-rise style models (gt-ebuq).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub initialization_equations: Option<Vec<Equation>>,

    /// Initial-guess seeds for nonlinear solvers during initialization, keyed
    /// by variable name. Values may be numeric literals or Expression graphs.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub guesses: Option<HashMap<String, serde_json::Value>>,

    /// MTK system-kind discriminator: "ode" (default), "nonlinear", "sde", "pde".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub system_kind: Option<String>,
}

/// Variable within a model
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ModelVariable {
    /// Variable type
    #[serde(rename = "type")]
    pub var_type: VariableType,

    /// Physical units
    #[serde(skip_serializing_if = "Option::is_none")]
    pub units: Option<String>,

    /// Default/initial value
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default: Option<f64>,

    /// The unit the `default` VALUE is expressed in, when it is not the
    /// variable's declared `units` (schema `ModelVariable.default_units`).
    ///
    /// The schema's contract is that `default` is given in the declared `units`,
    /// so a `default_units` naming a DIFFERENT unit is a defect: `units: "K"`
    /// with `default: 25.0, default_units: "degC"` means the stored number is 25
    /// but the variable actually reads 298.15. Rust did not model the field at
    /// all, so the mismatch was silently dropped on load.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_units: Option<String>,

    /// Brief description
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,

    /// Arrayed-variable shape: ordered dimension names drawn from the
    /// enclosing model's domain.spatial. `None` means scalar.
    /// See discretization RFC §10.2.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub shape: Option<Vec<String>>,

    /// Staggered-grid location tag (e.g., "cell_center", "edge_normal",
    /// "vertex"). `None` means no explicit staggering.
    /// See discretization RFC §10.2.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub location: Option<String>,

    /// Parameter-only: draw the value from a distribution instead of fixing it
    /// at `default` (esm-spec §6.3, schema `ModelVariable.distribution`).
    /// Mutually exclusive with `default`. With no `update` the draw happens
    /// ONCE at setup (`sampled_parameters`); with `update.kind: "wiener"` it is
    /// redrawn every step with √dt scaling (`brownian_parameters`), which is
    /// what promotes the enclosing model to an SDE. This subsumes the 0.x
    /// `brownian` type's `noise_kind` / `correlation_group` tags: correlated
    /// noise is one vector-valued parameter carrying a `cov` matrix, which the
    /// tags never actually gave.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub distribution: Option<Distribution>,

    /// Parameter-only: when this parameter refreshes and what from
    /// (esm-spec §5.4). Absent means it never changes after setup. One
    /// mechanism replacing three 0.x constructs — the `brownian` type, the
    /// `discrete` type's `refresh` trigger, and the `discrete_parameters`
    /// event lists with their `functional_affect`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub update: Option<ParameterUpdateSpec>,
}

/// The bare variable: every optional field absent, `var_type` a `parameter`.
/// A manual impl because [`VariableType`] has no derivable default — `type`
/// is a required field on the wire — and of the two kinds only a parameter is
/// coherent with nothing else set (an unknown with no defining equation is a
/// structural error). Construction sites are still expected to state the type
/// they mean: `ModelVariable { var_type: .., ..Default::default() }`.
impl Default for ModelVariable {
    fn default() -> Self {
        ModelVariable {
            var_type: VariableType::Parameter,
            units: None,
            default: None,
            default_units: None,
            description: None,
            shape: None,
            location: None,
            distribution: None,
            update: None,
        }
    }
}

impl ModelVariable {
    /// Visit every Expression this variable carries, in a stable order.
    ///
    /// From esm 1.0.0 a variable has no `expression` field — an unknown's
    /// definition is an EQUATION. What is left on the variable is the
    /// parameter's `update`: each rule's `when` trigger, its `expression`
    /// value form, and the `unit_conversion` of a `from` binding. All three
    /// are Expression positions and so are subject to reference integrity
    /// (esm-spec §4.9.5), which is what this walk exists to serve.
    pub fn for_each_expression(&self, f: &mut impl FnMut(&Expr)) {
        let Some(spec) = &self.update else { return };
        for rule in spec.rules() {
            if let Some(when) = rule.when() {
                f(when);
            }
            let Some(value) = rule.value() else { continue };
            if let Some(expr) = &value.expression {
                f(expr);
            }
            if let Some(UnitConversion::Expression(expr)) =
                value.from.as_ref().and_then(|b| b.unit_conversion.as_ref())
            {
                f(expr);
            }
        }
    }

    /// As [`ModelVariable::for_each_expression`], but also handing the callback
    /// the JSON-pointer suffix of the SITE the expression came from, relative to
    /// the variable's `update`.
    ///
    /// A diagnostic must name the field it is about. Reporting every one of a
    /// parameter's update expressions at a bare `.../update` is ambiguous the
    /// moment the ordered ARRAY form is used (esm-spec §5.4) — and that form
    /// exists precisely because parameters written by two or more events are
    /// common — so `when`, `expression` and `from/unit_conversion` all have to
    /// be distinguishable, per rule. The suffixes match the other four
    /// bindings: `""` for the single-rule object form and `/i` for entry `i` of
    /// the array form, then the site (`/when`, `/expression`,
    /// `/from/unit_conversion`).
    pub fn for_each_expression_at(&self, f: &mut impl FnMut(&Expr, &str)) {
        let Some(spec) = &self.update else { return };
        let indexed = matches!(spec, ParameterUpdateSpec::Several(_));
        for (i, rule) in spec.rules().iter().enumerate() {
            let rule_path = if indexed {
                format!("/{i}")
            } else {
                String::new()
            };
            if let Some(when) = rule.when() {
                f(when, &format!("{rule_path}/when"));
            }
            let Some(value) = rule.value() else { continue };
            if let Some(expr) = &value.expression {
                f(expr, &format!("{rule_path}/expression"));
            }
            if let Some(UnitConversion::Expression(expr)) =
                value.from.as_ref().and_then(|b| b.unit_conversion.as_ref())
            {
                f(expr, &format!("{rule_path}/from/unit_conversion"));
            }
        }
    }

    /// Mutable counterpart of [`ModelVariable::for_each_expression`], for the
    /// namespacing / renaming / range-resolution passes.
    pub fn for_each_expression_mut(&mut self, f: &mut impl FnMut(&mut Expr)) {
        let Some(spec) = &mut self.update else { return };
        let rules: &mut [ParameterUpdate] = match spec {
            ParameterUpdateSpec::Single(rule) => std::slice::from_mut(rule),
            ParameterUpdateSpec::Several(rules) => rules,
        };
        for rule in rules {
            if let Some(when) = rule.when_mut() {
                f(when);
            }
            let Some(value) = rule.value_mut() else {
                continue;
            };
            if let Some(expr) = &mut value.expression {
                f(expr);
            }
            if let Some(UnitConversion::Expression(expr)) =
                value.from.as_mut().and_then(|b| b.unit_conversion.as_mut())
            {
                f(expr);
            }
        }
    }

    /// Error-propagating [`ModelVariable::for_each_expression_mut`]: visits
    /// the same expression set in the same order and returns the FIRST error
    /// `f` raises (later expressions are not passed to `f`, so they are left
    /// unmodified). Defined in terms of `for_each_expression_mut` itself, so
    /// the two can never disagree about which fields carry expressions.
    pub fn try_for_each_expression_mut<E>(
        &mut self,
        f: &mut impl FnMut(&mut Expr) -> Result<(), E>,
    ) -> Result<(), E> {
        let mut first_err: Option<E> = None;
        self.for_each_expression_mut(&mut |expr| {
            if first_err.is_none()
                && let Err(e) = f(expr)
            {
                first_err = Some(e);
            }
        });
        match first_err {
            Some(e) => Err(e),
            None => Ok(()),
        }
    }

    /// The `data_sources` keys this variable's update rules read from.
    pub fn update_sources(&self) -> Vec<&str> {
        self.update
            .iter()
            .flat_map(|spec| spec.rules())
            .filter_map(|rule| rule.data_source())
            .collect()
    }
}

/// A parameter's value drawn from a probability distribution rather than fixed
/// (esm-spec §6.3, schema `Distribution`). The closed set is `normal`,
/// `lognormal`, `uniform` — bindings implement exactly these and reject
/// anything else.
///
/// Univariate when the location parameter is a number, multivariate when it is
/// an array — in which case `cov` gives the full covariance matrix and the
/// parameter's `shape` must agree.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Distribution {
    /// Gaussian. Exactly one of `std` (independent components) or `cov`.
    Normal {
        /// Mean — a number (scalar) or one entry per component (vector).
        mean: DistributionParam,
        /// Standard deviation of INDEPENDENT components. Excludes `cov`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        std: Option<DistributionParam>,
        /// Full covariance matrix, row-major. Excludes `std`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cov: Option<CovarianceMatrix>,
    },
    /// Log-normal: `ln(value)` is normal with mean `mu` and spread
    /// `sigma` / `cov` (both on the LOG scale).
    Lognormal {
        /// Mean of the underlying normal (log scale).
        mu: DistributionParam,
        /// Standard deviation of the underlying normal. Excludes `cov`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        sigma: Option<DistributionParam>,
        /// Full covariance matrix on the log scale. Excludes `sigma`.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        cov: Option<CovarianceMatrix>,
    },
    /// Uniform on `[low, high]`. Components are independent by construction, so
    /// there is no covariance form.
    Uniform {
        /// Lower bound(s).
        low: DistributionParam,
        /// Upper bound(s).
        high: DistributionParam,
    },
}

impl Distribution {
    /// The distribution's `kind` string, as it appears on the wire.
    pub fn kind(&self) -> &'static str {
        match self {
            Distribution::Normal { .. } => "normal",
            Distribution::Lognormal { .. } => "lognormal",
            Distribution::Uniform { .. } => "uniform",
        }
    }

    /// The LOCATION parameter (`mean` / `mu` / `low`), whose form decides
    /// whether the distribution is univariate or multivariate.
    pub fn location(&self) -> &DistributionParam {
        match self {
            Distribution::Normal { mean, .. } => mean,
            Distribution::Lognormal { mu, .. } => mu,
            Distribution::Uniform { low, .. } => low,
        }
    }

    /// True when the location parameter is an array — the schema's
    /// univariate/multivariate discriminator.
    pub fn is_multivariate(&self) -> bool {
        self.location().is_vector()
    }

    /// The full covariance matrix, when this distribution carries one.
    pub fn cov(&self) -> Option<&CovarianceMatrix> {
        match self {
            Distribution::Normal { cov, .. } | Distribution::Lognormal { cov, .. } => cov.as_ref(),
            Distribution::Uniform { .. } => None,
        }
    }
}

/// A distribution's location/scale parameter: a number for a scalar parameter,
/// an array for a vector-valued one.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum DistributionParam {
    /// Scalar (univariate) form.
    Scalar(f64),
    /// Per-component (multivariate) form.
    Vector(Vec<f64>),
}

impl DistributionParam {
    /// True when this is the multivariate (array) form.
    pub fn is_vector(&self) -> bool {
        matches!(self, DistributionParam::Vector(_))
    }
}

/// Symmetric positive-semidefinite covariance matrix, row-major: entry
/// `[i][j]` is the covariance of components `i` and `j`.
pub type CovarianceMatrix = Vec<Vec<f64>>;

/// A parameter's update behaviour (esm-spec §5.4, schema
/// `ParameterUpdateSpec`): EITHER a single rule, OR an ordered array of two or
/// more applied in declaration order.
///
/// A single rule MUST be the object form — a one-element array is invalid — so
/// every update set has exactly one spelling and the round trip is stable.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
// The single form carries a whole `ParameterUpdate` inline while the array form
// carries a `Vec`, so the variants differ in size. Boxing the single one would
// pay an allocation on the COMMON spelling — most parameters carry one rule —
// to shrink a type that lives once per variable and is never in a hot loop, and
// it would cost the wire-facing `ParameterUpdateSpec::Single(rule)` match
// ergonomics on the way. Same call as `DiscreteEventTrigger` above.
#[allow(clippy::large_enum_variant)]
pub enum ParameterUpdateSpec {
    /// The object form: exactly one rule.
    Single(ParameterUpdate),
    /// The array form: two or more rules, applied in declaration order.
    Several(Vec<ParameterUpdate>),
}

impl ParameterUpdateSpec {
    /// The rules, in declaration order. The single form yields a one-element
    /// slice, so every consumer reads one shape.
    pub fn rules(&self) -> &[ParameterUpdate] {
        match self {
            ParameterUpdateSpec::Single(rule) => std::slice::from_ref(rule),
            ParameterUpdateSpec::Several(rules) => rules,
        }
    }

    /// True iff ANY rule is `wiener` — the `brownian_parameters` test
    /// (esm-spec §6.3.1). The schema forbids `wiener` inside the array form,
    /// so in practice only the single form can answer true.
    pub fn is_wiener(&self) -> bool {
        self.rules()
            .iter()
            .any(|r| matches!(r, ParameterUpdate::Wiener))
    }

    /// True iff any rule requires the variable to declare a `shape` —
    /// `schedule`, `data`, or `remesh` (esm-spec §5.4 "Cadence"): such a
    /// parameter is a buffer whose extent is fixed at setup.
    pub fn requires_shape(&self) -> bool {
        self.rules().iter().any(|r| {
            matches!(
                r,
                ParameterUpdate::Schedule { .. }
                    | ParameterUpdate::Data { .. }
                    | ParameterUpdate::Remesh { .. }
            )
        })
    }
}

/// One update rule: WHEN a parameter refreshes, and WHAT from
/// (esm-spec §5.4). Every kind except `wiener` carries exactly one value form
/// — `expression`, `from`, or `handler` — held in the flattened
/// [`UpdateValue`]; `wiener` carries none, because the parameter's
/// `distribution` IS its value.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ParameterUpdate {
    /// A driving Wiener (Brownian) process: the parameter's `distribution` is
    /// resampled every step with √dt increment scaling. Any such parameter
    /// promotes the enclosing model from an ODE system to an SDE system.
    Wiener,
    /// Time-driven refresh at preset `times` and/or on a periodic `interval`
    /// (at least one of the two is present) — the MTK `PresetTimeCallback` /
    /// `tstops` analogue.
    Schedule {
        /// Explicit simulation times (the tstops) at which to refresh.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        times: Option<Vec<f64>>,
        /// Periodic refresh interval in simulation time units.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        interval: Option<f64>,
        /// Offset from t=0 for the first periodic refresh.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        initial_offset: Option<f64>,
        /// The value form.
        #[serde(flatten)]
        value: UpdateValue,
    },
    /// Refresh at the end of any timestep at which the boolean `when` is true.
    Condition {
        /// Boolean expression tested at the end of each timestep.
        when: Expr,
        /// The value form.
        #[serde(flatten)]
        value: UpdateValue,
    },
    /// Refresh when `when` crosses zero, located by root-finding.
    Crossing {
        /// Expression whose zero crossing triggers the refresh.
        when: Expr,
        /// Which crossings count: `up`, `down`, or `any` (the default).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        direction: Option<String>,
        /// The value form.
        #[serde(flatten)]
        value: UpdateValue,
    },
    /// Refresh when the named `data_sources` entry advances a record.
    Data {
        /// Key of the `data_sources` entry driving the refresh. MUST resolve
        /// (`data_source_undefined`).
        source: String,
        /// The value form.
        #[serde(flatten)]
        value: UpdateValue,
    },
    /// Refresh on a mesh-topology change (AMR refinement, moving mesh).
    Remesh {
        /// Optional name of the remesh hook. Absent ⇒ any remesh event.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        hook: Option<String>,
        /// The value form.
        #[serde(flatten)]
        value: UpdateValue,
    },
}

impl ParameterUpdate {
    /// The rule's `kind` string, as it appears on the wire.
    pub fn kind(&self) -> &'static str {
        match self {
            ParameterUpdate::Wiener => "wiener",
            ParameterUpdate::Schedule { .. } => "schedule",
            ParameterUpdate::Condition { .. } => "condition",
            ParameterUpdate::Crossing { .. } => "crossing",
            ParameterUpdate::Data { .. } => "data",
            ParameterUpdate::Remesh { .. } => "remesh",
        }
    }

    /// The rule's value form, or `None` for `wiener` (which has none).
    pub fn value(&self) -> Option<&UpdateValue> {
        match self {
            ParameterUpdate::Wiener => None,
            ParameterUpdate::Schedule { value, .. }
            | ParameterUpdate::Condition { value, .. }
            | ParameterUpdate::Crossing { value, .. }
            | ParameterUpdate::Data { value, .. }
            | ParameterUpdate::Remesh { value, .. } => Some(value),
        }
    }

    /// Mutable access to the rule's value form, or `None` for `wiener`.
    pub fn value_mut(&mut self) -> Option<&mut UpdateValue> {
        match self {
            ParameterUpdate::Wiener => None,
            ParameterUpdate::Schedule { value, .. }
            | ParameterUpdate::Condition { value, .. }
            | ParameterUpdate::Crossing { value, .. }
            | ParameterUpdate::Data { value, .. }
            | ParameterUpdate::Remesh { value, .. } => Some(value),
        }
    }

    /// The boolean/zero-crossing trigger expression (`condition` / `crossing`).
    pub fn when(&self) -> Option<&Expr> {
        match self {
            ParameterUpdate::Condition { when, .. } | ParameterUpdate::Crossing { when, .. } => {
                Some(when)
            }
            _ => None,
        }
    }

    /// Mutable access to the trigger expression (`condition` / `crossing`).
    pub fn when_mut(&mut self) -> Option<&mut Expr> {
        match self {
            ParameterUpdate::Condition { when, .. } | ParameterUpdate::Crossing { when, .. } => {
                Some(when)
            }
            _ => None,
        }
    }

    /// The `data_sources` key this rule refreshes from, for the `data` kind.
    pub fn data_source(&self) -> Option<&str> {
        match self {
            ParameterUpdate::Data { source, .. } => Some(source.as_str()),
            _ => None,
        }
    }
}

/// The value form of an update rule: exactly one of `expression`, `from`, or
/// `handler` (esm-spec §5.4, "What: exactly one value form"). Modelled as three
/// options rather than an enum so the flattened round trip stays verbatim; the
/// "exactly one" constraint is a schema-layer check.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct UpdateValue {
    /// The new value, computed symbolically (§4).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expression: Option<Expr>,

    /// The new value, read from the `data_sources` entry named by
    /// `update.source` (§8).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub from: Option<DataSourceBinding>,

    /// The new value, computed by a registered handler (§5.5).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub handler: Option<FunctionalUpdate>,
}

/// A registered handler computing a parameter's new value when its update
/// fires (esm-spec §5.5). The 0.x event `functional_affect`, relocated onto the
/// parameter it writes — which is why it needs no `modified_params` list: it
/// writes exactly one thing, the parameter carrying it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FunctionalUpdate {
    /// Registered identifier for the handler implementation.
    pub handler_id: String,

    /// Unknowns read by the handler. Absent means none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub read_vars: Option<Vec<String>>,

    /// Parameters read by the handler. Absent means none.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub read_params: Option<Vec<String>>,

    /// Handler-specific configuration, passed through verbatim.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub config: Option<serde_json::Value>,
}

/// Binds a parameter to ONE variable of a `data_sources` entry (esm-spec §8.5).
/// The 0.x `DataLoaderVariable` minus `units`: the units are the parameter's
/// own, declared once on the parameter instead of twice.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DataSourceBinding {
    /// Name of the variable in the source file supplying the values.
    pub file_variable: String,

    /// Multiplicative factor or Expression AST reaching the parameter's
    /// declared `units`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unit_conversion: Option<UnitConversion>,

    /// Text-label decoding table, passed through verbatim.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub codes: Option<serde_json::Value>,

    /// Per-parameter override of the source-level `select`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub select: Option<serde_json::Value>,

    /// Brief description.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,

    /// Academic citation or data source reference.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reference: Option<Reference>,
}

/// Type of model variable (esm-spec §6.3). There are **two** declared types
/// and no third: everything else a solver needs — which unknowns are ODE
/// states, which parameters are Brownian — is DERIVED by
/// [`crate::classification`], never declared.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum VariableType {
    /// A quantity the solver solves for. Its behaviour is stated by the
    /// model's `equations` and NOWHERE else — there is no `expression` field
    /// on a variable. Subsumes the 0.x `state` and `observed` types; which of
    /// the two an unknown is follows from the form of the equation LHS that
    /// defines it ([`crate::classification::ode_states`] /
    /// [`crate::classification::observed_unknowns`] /
    /// [`crate::classification::algebraic_unknowns`]).
    Unknown,
    /// A quantity supplied to the solver. Its value is `default` or a
    /// `distribution`, optionally refreshed by an `update` (§5.4). Subsumes
    /// the 0.x `parameter`, `brownian` and `discrete` types
    /// ([`crate::classification::brownian_parameters`] /
    /// [`crate::classification::discrete_parameters`] /
    /// [`crate::classification::sampled_parameters`] /
    /// [`crate::classification::constant_parameters`]).
    Parameter,
}

/// Differential equation
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Equation {
    /// Left-hand side expression
    pub lhs: Expr,

    /// Right-hand side expression
    pub rhs: Expr,

    /// Author's annotation on this equation (schema `Equation._comment`).
    /// The schema allows it explicitly alongside `additionalProperties:
    /// false`, so it is normative document content and must survive
    /// `parse → emit` — the field exists purely for that pass-through.
    #[serde(rename = "_comment", default, skip_serializing_if = "Option::is_none")]
    pub comment: Option<String>,
}

impl Default for Equation {
    fn default() -> Self {
        Equation {
            lhs: Expr::Integer(0),
            rhs: Expr::Integer(0),
            comment: None,
        }
    }
}
