//! Strip and expose (API_SPEC §5.8, "Strip and expose"; RFC U6, issue #543).
//!
//! `esm_problem` with [`ProblemOptions::strip`](crate::ProblemOptions::strip)
//! removes the named construct classes from the document before the build,
//! builds the rest unchanged, and keeps the removed constructs as a
//! [`StrippedConstructs`]. Stripping is a document rewrite so every build stage
//! (the pipeline, value invention, providers, forcing) runs on the stripped
//! document exactly as it runs on any other. The constructs themselves are
//! read off the flattened ORIGINAL document, so their names are the flattened
//! names the kernels (`crate::compile_kernels`) are compiled against.

use crate::compile_error::CompileError;
use crate::flatten::{ComponentEvent, FlattenedSystem, TermOrigin};
use crate::simulate::SimulateError;
use crate::types::{
    ContinuousEvent, CouplingEntry, DiscreteEvent, DiscreteEventTrigger, EsmFile, Expr, Model,
    ModelVariable, ParameterUpdate, ParameterUpdateSpec,
};
use serde_json::{Map, Value};
use std::collections::{BTreeSet, HashMap, HashSet};

// ============================================================================
// The classes
// ============================================================================

/// The construct classes `esm_problem` strips (API_SPEC §5.8). Combine with
/// `|`; the empty set is the default and changes nothing.
#[derive(Clone, Copy, Default, PartialEq, Eq, Hash)]
pub struct StripSet(u8);

impl StripSet {
    /// Strip nothing.
    pub const EMPTY: StripSet = StripSet(0);
    /// Every `continuous_events` entry, and every `crossing` parameter update
    /// (together with [`Self::PARAMETER_UPDATES`]).
    pub const CONTINUOUS_EVENTS: StripSet = StripSet(1);
    /// Every `discrete_events` entry.
    pub const DISCRETE_EVENTS: StripSet = StripSet(2);
    /// Every symbolic parameter update (`schedule`, `condition`, `crossing`
    /// with an `expression` value).
    pub const PARAMETER_UPDATES: StripSet = StripSet(4);
    /// Every implicit equation; its algebraic unknowns move from `u` to `z`.
    pub const ALGEBRAIC: StripSet = StripSet(8);

    const NAMES: [(&'static str, StripSet); 4] = [
        ("algebraic", StripSet::ALGEBRAIC),
        ("continuous_events", StripSet::CONTINUOUS_EVENTS),
        ("discrete_events", StripSet::DISCRETE_EVENTS),
        ("parameter_updates", StripSet::PARAMETER_UPDATES),
    ];

    /// The class a vocabulary name spells, or `None` for any other name
    /// (`wiener` included: Wiener noise is never strippable).
    pub fn parse(name: &str) -> Option<StripSet> {
        Self::NAMES
            .iter()
            .find(|(n, _)| *n == name)
            .map(|(_, c)| *c)
    }

    /// The set of the named classes; an unknown name is an error naming it.
    pub fn from_names<'a>(names: impl IntoIterator<Item = &'a str>) -> Result<StripSet, String> {
        let mut out = StripSet::EMPTY;
        for n in names {
            out |= Self::parse(n).ok_or_else(|| {
                format!(
                    "`strip` names '{n}', which is not a strippable class; the classes are \
                     algebraic, continuous_events, discrete_events and parameter_updates \
                     (Wiener noise is never strippable)"
                )
            })?;
        }
        Ok(out)
    }

    /// Whether every class of `other` is in this set.
    pub fn contains(self, other: StripSet) -> bool {
        self.0 & other.0 == other.0
    }

    /// Whether the set names no class.
    pub fn is_empty(self) -> bool {
        self.0 == 0
    }

    /// The names of the classes in the set, ascending.
    pub fn names(self) -> Vec<&'static str> {
        Self::NAMES
            .iter()
            .filter(|(_, c)| self.contains(*c))
            .map(|(n, _)| *n)
            .collect()
    }
}

impl std::ops::BitOr for StripSet {
    type Output = StripSet;
    fn bitor(self, rhs: StripSet) -> StripSet {
        StripSet(self.0 | rhs.0)
    }
}

impl std::ops::BitOrAssign for StripSet {
    fn bitor_assign(&mut self, rhs: StripSet) {
        self.0 |= rhs.0;
    }
}

impl std::fmt::Debug for StripSet {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_set().entries(self.names()).finish()
    }
}

// ============================================================================
// The stripped object
// ============================================================================

/// `"continuous"` or `"discrete"`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum EventKind {
    /// A `continuous_events` entry (or a coupling event of that type).
    Continuous,
    /// A `discrete_events` entry (or a coupling event of that type).
    Discrete,
}

impl EventKind {
    fn as_str(self) -> &'static str {
        match self {
            EventKind::Continuous => "continuous",
            EventKind::Discrete => "discrete",
        }
    }
}

/// One removed event, flattened and namespaced.
#[derive(Debug, Clone)]
pub struct StrippedEvent {
    /// The name a kernel spec refers to it by (`<prefix>.<name>`, or
    /// `<prefix>.<kind>_event[j]` when unnamed).
    pub id: String,
    /// `{"component": path}` or `{"coupling": k}`.
    pub origin: TermOrigin,
    /// Continuous or discrete.
    pub kind: EventKind,
    /// The authored event's members, namespaced (the canonical JSON's
    /// members other than `id`, `origin` and `kind`).
    pub body: Map<String, Value>,
    pub(crate) conditions: Vec<Expr>,
    pub(crate) trigger: Option<Expr>,
    pub(crate) affects: Vec<(String, Expr)>,
    pub(crate) affect_neg: Option<Vec<(String, Expr)>>,
}

/// One stripped parameter and its update rules.
#[derive(Debug, Clone)]
pub struct StrippedUpdate {
    /// The flattened parameter name.
    pub parameter: String,
    /// The component that declared it.
    pub origin: TermOrigin,
    /// Its rules, namespaced, as JSON.
    pub rules: Vec<Value>,
    pub(crate) values: Vec<Expr>,
}

/// One stripped implicit equation, as the residual `lhs - rhs`.
#[derive(Debug, Clone)]
pub struct StrippedResidual {
    /// `<prefix>.residual[j]`.
    pub id: String,
    /// The origin of the equation's first contribution.
    pub origin: TermOrigin,
    /// Its extents (`[]` for a scalar).
    pub shape: Vec<usize>,
    /// `{"op": "-", "args": [lhs, rhs]}`.
    pub expr: Expr,
    pub(crate) sets: Vec<String>,
}

/// One block of the `z` layout.
#[derive(Debug, Clone)]
pub struct ZBlock {
    /// The flattened unknown.
    pub name: String,
    /// The 0-based offset of its first element in `z`.
    pub offset: usize,
    /// Its extents (`[]` for a scalar).
    pub shape: Vec<usize>,
}

/// What `strip` removed (API_SPEC §5.8, "The stripped object"). Empty when
/// nothing was requested or nothing was found.
#[derive(Debug, Clone, Default)]
pub struct StrippedConstructs {
    pub(crate) strip: StripSet,
    pub(crate) events: Vec<StrippedEvent>,
    pub(crate) parameter_updates: Vec<StrippedUpdate>,
    pub(crate) z_layout: Vec<ZBlock>,
    pub(crate) z0: Vec<Option<f64>>,
    pub(crate) residuals: Vec<StrippedResidual>,
}

impl StrippedConstructs {
    /// The classes the caller requested.
    pub fn strip(&self) -> StripSet {
        self.strip
    }

    /// The removed events, in the order of API_SPEC §5.8.
    pub fn events(&self) -> &[StrippedEvent] {
        &self.events
    }

    /// The stripped parameters and their rules.
    pub fn parameter_updates(&self) -> &[StrippedUpdate] {
        &self.parameter_updates
    }

    /// The `z` unknowns, in `z` layout order.
    pub fn algebraic_unknowns(&self) -> Vec<&str> {
        self.z_layout.iter().map(|b| b.name.as_str()).collect()
    }

    /// The `z` layout.
    pub fn z_layout(&self) -> &[ZBlock] {
        &self.z_layout
    }

    /// The length of `z`.
    pub fn n_z(&self) -> usize {
        self.z_layout
            .iter()
            .map(|b| b.shape.iter().product::<usize>().max(1))
            .sum()
    }

    /// The starting value of every `z` element (`None` where the document
    /// gives none).
    pub fn z0(&self) -> &[Option<f64>] {
        &self.z0
    }

    /// The stripped implicit equations, as residuals.
    pub fn residuals(&self) -> &[StrippedResidual] {
        &self.residuals
    }

    /// Whether anything was removed. A Problem is stripped exactly when this
    /// is false.
    pub fn is_empty(&self) -> bool {
        self.events.is_empty() && self.parameter_updates.is_empty() && self.residuals.is_empty()
    }

    /// The classes whose constructs were actually removed, ascending.
    pub fn removed_classes(&self) -> Vec<&'static str> {
        let mut set = StripSet::EMPTY;
        for e in &self.events {
            set |= match e.kind {
                EventKind::Continuous => StripSet::CONTINUOUS_EVENTS,
                EventKind::Discrete => StripSet::DISCRETE_EVENTS,
            };
        }
        if !self.parameter_updates.is_empty() {
            set |= StripSet::PARAMETER_UPDATES;
        }
        if !self.residuals.is_empty() {
            set |= StripSet::ALGEBRAIC;
        }
        set.names()
    }

    /// The object as a JSON value (API_SPEC §5.8).
    pub fn to_json(&self) -> Value {
        let mut root = Map::new();
        root.insert(
            "strip".into(),
            Value::Array(
                self.strip
                    .names()
                    .into_iter()
                    .map(|n| Value::String(n.into()))
                    .collect(),
            ),
        );
        root.insert(
            "events".into(),
            Value::Array(
                self.events
                    .iter()
                    .map(|e| {
                        let mut m = e.body.clone();
                        m.insert("id".into(), Value::String(e.id.clone()));
                        m.insert("origin".into(), origin_json(&e.origin));
                        m.insert("kind".into(), Value::String(e.kind.as_str().into()));
                        Value::Object(m)
                    })
                    .collect(),
            ),
        );
        root.insert(
            "parameter_updates".into(),
            Value::Array(
                self.parameter_updates
                    .iter()
                    .map(|u| {
                        let mut m = Map::new();
                        m.insert("parameter".into(), Value::String(u.parameter.clone()));
                        m.insert("origin".into(), origin_json(&u.origin));
                        m.insert("rules".into(), Value::Array(u.rules.clone()));
                        Value::Object(m)
                    })
                    .collect(),
            ),
        );
        let mut alg = Map::new();
        alg.insert(
            "unknowns".into(),
            Value::Array(
                self.z_layout
                    .iter()
                    .map(|b| Value::String(b.name.clone()))
                    .collect(),
            ),
        );
        let mut zl = Map::new();
        for b in &self.z_layout {
            let mut m = Map::new();
            m.insert("base".into(), Value::from(b.offset + 1));
            m.insert(
                "shape".into(),
                Value::Array(b.shape.iter().map(|&n| Value::from(n)).collect()),
            );
            zl.insert(b.name.clone(), Value::Object(m));
        }
        alg.insert("z_layout".into(), Value::Object(zl));
        alg.insert(
            "z0".into(),
            Value::Array(
                self.z0
                    .iter()
                    .map(|v| match v {
                        Some(x) if x.is_finite() => number_json(*x),
                        _ => Value::Null,
                    })
                    .collect(),
            ),
        );
        alg.insert(
            "residuals".into(),
            Value::Array(
                self.residuals
                    .iter()
                    .map(|r| {
                        let mut m = Map::new();
                        m.insert("id".into(), Value::String(r.id.clone()));
                        m.insert("origin".into(), origin_json(&r.origin));
                        m.insert(
                            "shape".into(),
                            Value::Array(r.shape.iter().map(|&n| Value::from(n)).collect()),
                        );
                        m.insert("expr".into(), expr_json(&r.expr));
                        Value::Object(m)
                    })
                    .collect(),
            ),
        );
        root.insert("algebraic".into(), Value::Object(alg));
        Value::Object(root)
    }

    /// The canonical JSON of [`Self::to_json`]: compact, keys ascending, numbers
    /// in the CONFORMANCE_SPEC §5.5.3.1 form. Byte-identical across bindings.
    pub fn canonical_json(&self) -> String {
        canonical_json_value(&self.to_json())
    }
}

fn origin_json(o: &TermOrigin) -> Value {
    serde_json::to_value(o).unwrap_or(Value::Null)
}

fn number_json(x: f64) -> Value {
    serde_json::Number::from_f64(x).map_or(Value::Null, Value::Number)
}

pub(crate) fn expr_json(e: &Expr) -> Value {
    serde_json::to_value(e).unwrap_or(Value::Null)
}

/// Compact JSON with every object's keys in ascending byte order and every
/// number in the §5.5.3.1 canonical form (an integral value in `i64` range as
/// an integer literal, any other as the shortest round-trip float).
pub(crate) fn canonical_json_value(v: &Value) -> String {
    let mut out = String::new();
    write_canonical(v, &mut out);
    out
}

fn write_canonical(v: &Value, out: &mut String) {
    match v {
        Value::Null => out.push_str("null"),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                out.push_str(&i.to_string());
            } else if let Some(u) = n.as_u64() {
                out.push_str(&u.to_string());
            } else {
                let f = n.as_f64().unwrap_or(f64::NAN);
                if f.fract() == 0.0 && f.abs() < 9.2e18 {
                    out.push_str(&(f as i64).to_string());
                } else {
                    out.push_str(&crate::canonicalize::format_julia_float(f));
                }
            }
        }
        Value::String(s) => {
            out.push_str(&serde_json::to_string(s).expect("a string serializes"));
        }
        Value::Array(a) => {
            out.push('[');
            for (k, x) in a.iter().enumerate() {
                if k > 0 {
                    out.push(',');
                }
                write_canonical(x, out);
            }
            out.push(']');
        }
        Value::Object(m) => {
            let mut keys: Vec<&String> = m.keys().collect();
            keys.sort();
            out.push('{');
            for (k, key) in keys.into_iter().enumerate() {
                if k > 0 {
                    out.push(',');
                }
                out.push_str(&serde_json::to_string(key).expect("a string serializes"));
                out.push(':');
                write_canonical(&m[key], out);
            }
            out.push('}');
        }
    }
}

// ============================================================================
// Errors
// ============================================================================

pub(crate) fn strip_error(code: &'static str, message: String) -> SimulateError {
    SimulateError::Strip { code, message }
}

// ============================================================================
// Which constructs a class takes
// ============================================================================

/// Whether `lhs` makes its equation a strippable implicit equation: an
/// expression or number LHS that is not a structural target (`ic`, a spatial
/// derivative) and not a time derivative of an expression (`D(a + b)`, a
/// misspelled equation that stays refused).
pub(crate) fn is_strippable_implicit(lhs: &Expr) -> bool {
    use crate::classification::{LhsFormRef, lhs_form_ref};
    if !matches!(lhs_form_ref(lhs), LhsFormRef::Expression) {
        return false;
    }
    let mut body = lhs;
    while let Expr::Operator(n) = body {
        if n.op == "faq"
            && let Some(inner) = n.expr.as_deref()
        {
            body = inner;
            continue;
        }
        break;
    }
    !matches!(
        body,
        Expr::Operator(n) if matches!(n.op.as_str(), "ic" | "D" | "grad" | "div" | "laplacian")
    )
}

/// Whether `spec` is a symbolic update `set` strips: every rule is
/// `schedule`, `condition` or `crossing` with an `expression` value, and a
/// `crossing` rule needs `continuous_events` too.
fn strips_update(spec: &ParameterUpdateSpec, set: StripSet) -> bool {
    if !set.contains(StripSet::PARAMETER_UPDATES) {
        return false;
    }
    spec.rules().iter().all(|r| {
        let symbolic = r
            .value()
            .is_some_and(|v| v.expression.is_some() && v.from.is_none() && v.handler.is_none());
        match r {
            ParameterUpdate::Schedule { .. } | ParameterUpdate::Condition { .. } => symbolic,
            ParameterUpdate::Crossing { .. } => {
                symbolic && set.contains(StripSet::CONTINUOUS_EVENTS)
            }
            _ => false,
        }
    })
}

fn strips_kind(kind: EventKind, set: StripSet) -> bool {
    match kind {
        EventKind::Continuous => set.contains(StripSet::CONTINUOUS_EVENTS),
        EventKind::Discrete => set.contains(StripSet::DISCRETE_EVENTS),
    }
}

// ============================================================================
// Stripping a document
// ============================================================================

/// The result of [`strip_file`]: the document the build runs, and what was
/// removed (its `z` starting values are filled by the caller).
pub(crate) struct Stripped {
    pub file: EsmFile,
    pub constructs: StrippedConstructs,
}

/// Refuse a coupling-level event (a `coupling` entry of `type: "event"`) that
/// `set` does not strip. No fast compiler runs one, and flatten records it only
/// as a description, so without this it would be dropped silently
/// (esm-spec §9.6.6 `unsupported_construct`).
pub(crate) fn refuse_coupling_events(file: &EsmFile, set: StripSet) -> Result<(), SimulateError> {
    for entry in file.coupling.iter().flatten() {
        if let CouplingEntry::Event {
            event_type, name, ..
        } = entry
        {
            let kind = if event_type == "continuous" {
                EventKind::Continuous
            } else {
                EventKind::Discrete
            };
            if !strips_kind(kind, set) {
                return Err(SimulateError::Compile(crate::compile_error::event_refusal(
                    match kind {
                        EventKind::Continuous => crate::compile_error::CONTINUOUS_EVENT,
                        EventKind::Discrete => crate::compile_error::DISCRETE_EVENT,
                    },
                    crate::compile_error::ARRAY_EVALUATOR,
                    name.as_deref()
                        .map(|n| format!("{n}' (a coupling-level event"))
                        .as_deref(),
                )));
            }
        }
    }
    Ok(())
}

/// Remove `set`'s constructs from `file`, and collect them from the flattened
/// original (API_SPEC §5.8). Coupling-level events stay in the document (the
/// build never lowers one; [`refuse_coupling_events`] is what refuses them),
/// so the coupling indices of the stripped document's provenance are the
/// original's.
pub(crate) fn strip_file(file: &EsmFile, set: StripSet) -> Result<Stripped, SimulateError> {
    let flat = crate::flatten::flatten(file).map_err(|e| SimulateError::Compile(e.into()))?;
    let mut out = file.clone();
    let mut constructs = StrippedConstructs {
        strip: set,
        ..Default::default()
    };

    // ---- events ----------------------------------------------------------
    let mut found: Vec<(String, ComponentEvent)> = Vec::new();
    for (name, model) in file.models.iter().flatten() {
        crate::flatten::namespaced_model_events(name, model, &mut found);
    }
    for (name, rs) in file.reaction_systems.iter().flatten() {
        crate::flatten::namespaced_reaction_events(name, rs, &mut found);
    }
    let mut counters: HashMap<(String, EventKind), usize> = HashMap::new();
    for (path, ev) in found {
        let kind = match ev {
            ComponentEvent::Continuous(_) => EventKind::Continuous,
            ComponentEvent::Discrete(_) => EventKind::Discrete,
        };
        if !strips_kind(kind, set) {
            continue;
        }
        let j = counters.entry((path.clone(), kind)).or_insert(0);
        *j += 1;
        let ordinal = *j;
        constructs.events.push(stripped_event(
            &path,
            TermOrigin::Component {
                component: path.clone(),
            },
            kind,
            ordinal,
            ev,
        )?);
    }
    for (k, entry) in file.coupling.iter().flatten().enumerate() {
        let CouplingEntry::Event { event_type, .. } = entry else {
            continue;
        };
        let kind = if event_type == "continuous" {
            EventKind::Continuous
        } else {
            EventKind::Discrete
        };
        if !strips_kind(kind, set) {
            continue;
        }
        let prefix = format!("coupling[{k}]");
        let j = counters.entry((prefix.clone(), kind)).or_insert(0);
        *j += 1;
        let ordinal = *j;
        constructs
            .events
            .push(coupling_event(&prefix, k, kind, ordinal, entry)?);
    }

    // ---- parameter updates ----------------------------------------------
    let mut stripped_params: Vec<String> = Vec::new();
    for (mname, model) in out.models.iter_mut().flatten() {
        strip_model_updates(mname, model, set, &mut stripped_params)?;
    }
    for (rname, rs) in out.reaction_systems.iter_mut().flatten() {
        for (pname, p) in rs.parameters.iter_mut() {
            if p.update.as_ref().is_some_and(|u| strips_update(u, set)) {
                p.update = None;
                stripped_params.push(format!("{rname}.{pname}"));
            }
        }
    }
    let stripped_set: HashSet<&String> = stripped_params.iter().collect();
    for (name, var) in &flat.parameters {
        if !stripped_set.contains(name) {
            continue;
        }
        let Some(spec) = var.update.as_ref() else {
            continue;
        };
        let rules: Vec<Value> = spec
            .rules()
            .iter()
            .map(|r| serde_json::to_value(r).unwrap_or(Value::Null))
            .collect();
        let values: Vec<Expr> = spec
            .rules()
            .iter()
            .filter_map(|r| r.value().and_then(|v| v.expression.clone()))
            .collect();
        let origin = name
            .rsplit_once('.')
            .map(|(p, _)| p.to_string())
            .unwrap_or_default();
        constructs.parameter_updates.push(StrippedUpdate {
            parameter: name.clone(),
            origin: TermOrigin::Component { component: origin },
            rules,
            values,
        });
    }

    // ---- events out of the document -------------------------------------
    if set.contains(StripSet::CONTINUOUS_EVENTS) || set.contains(StripSet::DISCRETE_EVENTS) {
        for (_, model) in out.models.iter_mut().flatten() {
            remove_model_events(model, set);
        }
        for (_, rs) in out.reaction_systems.iter_mut().flatten() {
            if set.contains(StripSet::CONTINUOUS_EVENTS) {
                rs.continuous_events = None;
            }
            if set.contains(StripSet::DISCRETE_EVENTS) {
                rs.discrete_events = None;
            }
            for v in rs.subsystems.iter_mut().flat_map(|s| s.values_mut()) {
                remove_json_events(v, set);
            }
        }
    }

    // ---- algebraic -------------------------------------------------------
    if set.contains(StripSet::ALGEBRAIC) {
        let mut removed = 0usize;
        for (_, model) in out.models.iter_mut().flatten() {
            removed += remove_model_implicit(model);
        }
        if removed > 0 {
            collect_algebraic(&flat, &mut constructs)?;
        }
    }
    Ok(Stripped {
        file: out,
        constructs,
    })
}

fn stripped_event(
    prefix: &str,
    origin: TermOrigin,
    kind: EventKind,
    ordinal: usize,
    ev: ComponentEvent,
) -> Result<StrippedEvent, SimulateError> {
    let (body, name, conditions, trigger, affects, affect_neg) = match ev {
        ComponentEvent::Continuous(e) => {
            let body = to_object(&e)?;
            let (name, conds, aff, neg) = continuous_parts(&e);
            (body, name, conds, None, aff, neg)
        }
        ComponentEvent::Discrete(e) => {
            let body = to_object(&e)?;
            let (name, trig, aff) = discrete_parts(&e);
            (body, name, Vec::new(), trig, aff, None)
        }
    };
    Ok(StrippedEvent {
        id: event_id(prefix, name.as_deref(), kind, ordinal),
        origin,
        kind,
        body,
        conditions,
        trigger,
        affects,
        affect_neg,
    })
}

fn coupling_event(
    prefix: &str,
    k: usize,
    kind: EventKind,
    ordinal: usize,
    entry: &CouplingEntry,
) -> Result<StrippedEvent, SimulateError> {
    let mut body = to_object(entry)?;
    for key in ["type", "event_type"] {
        body.remove(key);
    }
    let CouplingEntry::Event {
        name,
        conditions,
        trigger,
        affects,
        affect_neg,
        ..
    } = entry
    else {
        unreachable!("called on an event entry");
    };
    let pair = |a: &crate::types::AffectEquation| (a.lhs.clone(), a.rhs.clone());
    Ok(StrippedEvent {
        id: event_id(prefix, name.as_deref(), kind, ordinal),
        origin: TermOrigin::Coupling { coupling: k },
        kind,
        body,
        conditions: conditions.clone().unwrap_or_default(),
        trigger: match trigger {
            Some(DiscreteEventTrigger::Condition { expression }) => Some(expression.clone()),
            _ => None,
        },
        affects: affects.iter().flatten().map(pair).collect(),
        affect_neg: affect_neg.as_ref().map(|v| v.iter().map(pair).collect()),
    })
}

#[allow(clippy::type_complexity)]
fn continuous_parts(
    e: &ContinuousEvent,
) -> (
    Option<String>,
    Vec<Expr>,
    Vec<(String, Expr)>,
    Option<Vec<(String, Expr)>>,
) {
    let pair = |a: &crate::types::AffectEquation| (a.lhs.clone(), a.rhs.clone());
    (
        e.name.clone(),
        e.conditions.clone(),
        e.affects.iter().map(pair).collect(),
        e.affect_neg.as_ref().map(|v| v.iter().map(pair).collect()),
    )
}

#[allow(clippy::type_complexity)]
fn discrete_parts(e: &DiscreteEvent) -> (Option<String>, Option<Expr>, Vec<(String, Expr)>) {
    let trig = match &e.trigger {
        DiscreteEventTrigger::Condition { expression } => Some(expression.clone()),
        _ => None,
    };
    (
        e.name.clone(),
        trig,
        e.affects
            .iter()
            .flatten()
            .map(|a| (a.lhs.clone(), a.rhs.clone()))
            .collect(),
    )
}

fn event_id(prefix: &str, name: Option<&str>, kind: EventKind, ordinal: usize) -> String {
    match name {
        Some(n) => format!("{prefix}.{n}"),
        None => format!("{prefix}.{}_event[{ordinal}]", kind.as_str()),
    }
}

/// An event's members as the stripped object writes them (API_SPEC §5.8): the
/// defaults `root_find: "left"`, `reinitialize: false` and a trigger's
/// `initial_offset: 0` are omitted, and `affects` is always present.
fn to_object<T: serde::Serialize>(x: &T) -> Result<Map<String, Value>, SimulateError> {
    match serde_json::to_value(x) {
        Ok(Value::Object(mut m)) => {
            if m.get("root_find").and_then(|v| v.as_str()) == Some("left") {
                m.remove("root_find");
            }
            if m.get("reinitialize") == Some(&Value::Bool(false)) {
                m.remove("reinitialize");
            }
            if let Some(Value::Object(t)) = m.get_mut("trigger")
                && t.get("initial_offset").and_then(|v| v.as_f64()) == Some(0.0)
            {
                t.remove("initial_offset");
            }
            m.entry("affects")
                .or_insert_with(|| Value::Array(Vec::new()));
            Ok(m)
        }
        Ok(_) => Ok(Map::new()),
        Err(e) => Err(SimulateError::Compile(CompileError::build_err(format!(
            "strip: serializing an event: {e}"
        )))),
    }
}

fn strip_model_updates(
    path: &str,
    model: &mut Model,
    set: StripSet,
    out: &mut Vec<String>,
) -> Result<(), SimulateError> {
    for (vname, var) in model.variables.iter_mut() {
        if strips_var(var, set) {
            var.update = None;
            out.push(format!("{path}.{vname}"));
        }
    }
    if let Some(subs) = model.subsystems.as_mut() {
        for (key, value) in subs.iter_mut() {
            let Ok(mut sub) = serde_json::from_value::<Model>(value.clone()) else {
                continue;
            };
            let before = out.len();
            strip_model_updates(&format!("{path}.{key}"), &mut sub, set, out)?;
            if out.len() > before
                && let Some(vars) = value.get_mut("variables").and_then(|v| v.as_object_mut())
            {
                for name in &out[before..] {
                    let local = name.rsplit_once('.').map_or(name.as_str(), |(_, l)| l);
                    if let Some(Value::Object(v)) = vars.get_mut(local)
                        && name == &format!("{path}.{key}.{local}")
                    {
                        v.remove("update");
                    }
                }
            }
        }
    }
    Ok(())
}

fn strips_var(var: &ModelVariable, set: StripSet) -> bool {
    var.var_type == crate::types::VariableType::Parameter
        && var.update.as_ref().is_some_and(|u| strips_update(u, set))
}

fn remove_model_events(model: &mut Model, set: StripSet) {
    if set.contains(StripSet::CONTINUOUS_EVENTS) {
        model.continuous_events = None;
    }
    if set.contains(StripSet::DISCRETE_EVENTS) {
        model.discrete_events = None;
    }
    for v in model.subsystems.iter_mut().flat_map(|s| s.values_mut()) {
        remove_json_events(v, set);
    }
}

fn remove_json_events(value: &mut Value, set: StripSet) {
    let Some(obj) = value.as_object_mut() else {
        return;
    };
    if set.contains(StripSet::CONTINUOUS_EVENTS) {
        obj.remove("continuous_events");
    }
    if set.contains(StripSet::DISCRETE_EVENTS) {
        obj.remove("discrete_events");
    }
    if let Some(Value::Object(subs)) = obj.get_mut("subsystems") {
        for v in subs.values_mut() {
            remove_json_events(v, set);
        }
    }
}

fn remove_model_implicit(model: &mut Model) -> usize {
    let before = model.equations.len();
    model
        .equations
        .retain(|eq| !is_strippable_implicit(&eq.lhs));
    let mut removed = before - model.equations.len();
    for v in model.subsystems.iter_mut().flat_map(|s| s.values_mut()) {
        let Ok(mut sub) = serde_json::from_value::<Model>(v.clone()) else {
            continue;
        };
        let n = remove_model_implicit(&mut sub);
        if n > 0
            && let (Some(obj), Ok(eqs)) = (v.as_object_mut(), serde_json::to_value(&sub.equations))
        {
            obj.insert("equations".into(), eqs);
            if let Some(Value::Object(subs_json)) = obj.get_mut("subsystems")
                && let Some(subs) = sub.subsystems.as_ref()
            {
                for (k, sv) in subs {
                    subs_json.insert(k.clone(), sv.clone());
                }
            }
        }
        removed += n;
    }
    removed
}

/// The residuals and the `z` layout, read off the flattened original.
fn collect_algebraic(
    flat: &FlattenedSystem,
    out: &mut StrippedConstructs,
) -> Result<(), SimulateError> {
    let mut counters: HashMap<String, usize> = HashMap::new();
    let mut read: HashSet<String> = HashSet::new();
    for (k, eq) in flat.equations.iter().enumerate() {
        if !is_strippable_implicit(&eq.lhs) {
            continue;
        }
        let origin = flat
            .equation_contributions
            .get(k)
            .and_then(|c| c.first())
            .and_then(|c| c.origins.first())
            .cloned()
            .unwrap_or(TermOrigin::Component {
                component: String::new(),
            });
        let prefix = match &origin {
            TermOrigin::Component { component } => component.clone(),
            TermOrigin::Coupling { coupling } => format!("coupling[{coupling}]"),
        };
        let j = counters.entry(prefix.clone()).or_insert(0);
        *j += 1;
        let expr = residual_expr(&eq.lhs, &eq.rhs);
        let sets = expr_sets(&expr, flat).map_err(|why| {
            strip_error(
                crate::diagnostic::codes::KERNEL_OUTPUT_UNRESOLVED,
                format!("the residual of `{}`: {why}", crate::to_ascii(&eq.lhs)),
            )
        })?;
        for n in crate::simulate_array::free_variable_names(&expr) {
            read.insert(n);
        }
        out.residuals.push(StrippedResidual {
            id: format!("{prefix}.residual[{j}]"),
            origin,
            shape: set_sizes(&sets, flat),
            expr,
            sets,
        });
    }
    let mut z: Vec<String> = flat
        .algebraic_variables
        .keys()
        .filter(|n| read.contains(*n))
        .cloned()
        .collect();
    let shaped = |n: &String| {
        flat.state_variables
            .get(n)
            .and_then(|v| v.shape.as_ref())
            .is_some_and(|s| !s.is_empty())
    };
    z.sort_by(|a, b| (shaped(a), a).cmp(&(shaped(b), b)));
    let mut offset = 0usize;
    for name in z {
        let sets: Vec<String> = flat
            .state_variables
            .get(&name)
            .and_then(|v| v.shape.clone())
            .unwrap_or_default();
        let shape = set_sizes(&sets, flat);
        let len = shape.iter().product::<usize>().max(1);
        out.z_layout.push(ZBlock {
            name,
            offset,
            shape,
        });
        offset += len;
    }
    Ok(())
}

/// `{"op": "-", "args": [lhs, rhs]}`.
pub(crate) fn residual_expr(lhs: &Expr, rhs: &Expr) -> Expr {
    op_expr("-", vec![lhs.clone(), rhs.clone()])
}

pub(crate) fn op_expr(op: &str, args: Vec<Expr>) -> Expr {
    let v = serde_json::json!({
        "op": op,
        "args": args.iter().map(expr_json).collect::<Vec<_>>(),
    });
    serde_json::from_value(v).expect("an operator node deserializes")
}

/// The extents of the index sets `sets`, from the flattened registry.
pub(crate) fn set_sizes(sets: &[String], flat: &FlattenedSystem) -> Vec<usize> {
    sets.iter()
        .map(|s| {
            flat.index_sets
                .get(s)
                .and_then(|i| i.size)
                .map_or(0, |n| n.max(0) as usize)
        })
        .collect()
}

/// The index sets an expression's value ranges over (API_SPEC §5.8, "an
/// `expr` output's shape"): a top-level `faq`'s output ranges, a bare
/// variable's declared shape, an elementwise operator's common operand shape,
/// and otherwise scalar.
pub(crate) fn expr_sets(e: &Expr, flat: &FlattenedSystem) -> Result<Vec<String>, String> {
    match e {
        Expr::Integer(_) | Expr::Number(_) => Ok(Vec::new()),
        Expr::Variable(name) => Ok(declared_sets(name, flat).unwrap_or_default()),
        Expr::Operator(n) => match n.op.as_str() {
            "faq" => {
                let mut sets = Vec::new();
                for i in n.output_idx.iter().flatten() {
                    let set = n
                        .ranges
                        .as_ref()
                        .and_then(|r| r.get(i))
                        .and_then(range_set)
                        .ok_or_else(|| {
                            format!("the output range `{i}` does not name an index set")
                        })?;
                    sets.push(set);
                }
                Ok(sets)
            }
            "index" => Ok(Vec::new()),
            "Pre" => n
                .args
                .first()
                .map_or(Ok(Vec::new()), |a| expr_sets(a, flat)),
            _ => {
                let mut out: Vec<String> = Vec::new();
                for a in &n.args {
                    let s = expr_sets(a, flat)?;
                    if s.is_empty() {
                        continue;
                    }
                    if out.is_empty() {
                        out = s;
                    } else if out != s {
                        return Err(format!(
                            "operands of `{}` range over different index sets ({} and {})",
                            n.op,
                            out.join(", "),
                            s.join(", ")
                        ));
                    }
                }
                Ok(out)
            }
        },
    }
}

fn range_set(r: &crate::types::RangeSpec) -> Option<String> {
    let v = serde_json::to_value(r).ok()?;
    v.get("from").and_then(|f| f.as_str()).map(str::to_string)
}

/// The declared index sets of a flattened variable, `None` if it is not
/// declared.
pub(crate) fn declared_sets(name: &str, flat: &FlattenedSystem) -> Option<Vec<String>> {
    flat.state_variables
        .get(name)
        .or_else(|| flat.observed_variables.get(name))
        .or_else(|| flat.parameters.get(name))
        .map(|v| v.shape.clone().unwrap_or_default())
}

/// The `z` starting values: each unknown's `ic` equation evaluated at the
/// start of the run, else its declared default, column-major.
pub(crate) fn z_starting_values(
    flat: &FlattenedSystem,
    z: &[ZBlock],
    params: &HashMap<String, f64>,
) -> Vec<Option<f64>> {
    let index_sets: HashMap<String, crate::types::IndexSet> = flat
        .index_sets
        .iter()
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    let mut out = Vec::new();
    for b in z {
        let len = b.shape.iter().product::<usize>().max(1);
        let ic = flat
            .equations
            .iter()
            .find_map(|eq| match &eq.lhs {
                Expr::Operator(n)
                    if n.op == "ic"
                        && matches!(n.args.first(), Some(Expr::Variable(v)) if *v == b.name) =>
                {
                    Some(eq.rhs.clone())
                }
                _ => None,
            })
            .or_else(|| {
                flat.field_ics
                    .iter()
                    .find(|(t, _)| *t == b.name)
                    .map(|(_, r)| r.clone())
            });
        let values: Option<Vec<f64>> = ic
            .and_then(|rhs| {
                crate::simulate_array::eval_buildtime_values(&rhs, &index_sets, params).ok()
            })
            .or_else(|| {
                flat.state_variables
                    .get(&b.name)
                    .and_then(|v| v.default.as_ref())
                    .and_then(|d| match d {
                        crate::types::InlineValue::Scalar(x) => Some(vec![*x]),
                        other => other.to_dense().ok().map(|(shape, rm)| {
                            crate::simulate_array::row_major_to_column_major(&shape, &rm)
                        }),
                    })
            });
        match values {
            Some(v) if v.len() == 1 => out.extend(std::iter::repeat_n(Some(v[0]), len)),
            Some(v) if v.len() == len => out.extend(v.into_iter().map(Some)),
            _ => out.extend(std::iter::repeat_n(None, len)),
        }
    }
    out
}

/// The variables `e` reads by bare name, outside every `Pre(·)`.
pub(crate) fn bare_reads(e: &Expr, out: &mut BTreeSet<String>) {
    bare_only(e, out);
}

fn bare_only(e: &Expr, out: &mut BTreeSet<String>) {
    match e {
        Expr::Variable(v) => {
            out.insert(v.clone());
        }
        Expr::Operator(n) if n.op == "Pre" => {}
        Expr::Operator(n) => {
            for a in &n.args {
                bare_only(a, out);
            }
            if let Some(b) = n.expr.as_deref() {
                bare_only(b, out);
            }
        }
        _ => {}
    }
}

/// `e` with every `Pre(x)` replaced by `x`: a kernel reads its input.
pub(crate) fn strip_pre(e: &Expr) -> Expr {
    match e {
        Expr::Operator(n) if n.op == "Pre" && n.args.len() == 1 => strip_pre(&n.args[0]),
        Expr::Operator(n) => {
            let mut node = (**n).clone();
            node.args = node.args.iter().map(strip_pre).collect();
            if let Some(b) = node.expr.as_deref() {
                node.expr = Some(Box::new(strip_pre(b)));
            }
            Expr::Operator(std::sync::Arc::new(node))
        }
        other => other.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strip_set_parses_and_names() {
        let s = StripSet::from_names(["discrete_events", "algebraic"]).unwrap();
        assert_eq!(s.names(), vec!["algebraic", "discrete_events"]);
        assert!(StripSet::from_names(["wiener"]).is_err());
        assert!(StripSet::EMPTY.is_empty());
    }

    #[test]
    fn canonical_json_sorts_and_normalizes() {
        let v = serde_json::json!({"b": 2.0, "a": [1.5, 1e-9, "x"], "c": {"z": null, "y": true}});
        assert_eq!(
            canonical_json_value(&v),
            r#"{"a":[1.5,1.0e-9,"x"],"b":2,"c":{"y":true,"z":null}}"#
        );
    }
}
