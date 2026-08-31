use super::*;
use serde::{Deserialize, Serialize};

/// Discrete event that can modify the system
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiscreteEvent {
    /// Human-readable identifier
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,

    /// When the event fires
    pub trigger: DiscreteEventTrigger,

    /// What happens when the event fires
    #[serde(skip_serializing_if = "Option::is_none")]
    pub affects: Option<Vec<AffectEquation>>,

    /// Whether to reinitialize the system after the event
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reinitialize: Option<bool>,

    /// Brief description
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// Trigger condition for discrete events
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
// Boxing the large variant would change the wire-facing construction/match
// ergonomics on one of the crate's most-touched types for a size win that
// profiling has not justified; when a variant IS boxed the field carries its
// own rationale (see AssertionReference::Expression).
#[allow(clippy::large_enum_variant)]
pub enum DiscreteEventTrigger {
    /// Fires when boolean condition is true
    Condition { expression: Expr },
    /// Fires at regular intervals
    Periodic {
        /// Interval in simulation time units
        interval: f64,
        /// Offset from t=0 for first firing
        #[serde(skip_serializing_if = "Option::is_none")]
        initial_offset: Option<f64>,
    },
    /// Fires at preset times
    PresetTimes {
        /// Array of simulation times at which to fire
        times: Vec<f64>,
    },
}

/// Equation that modifies state/parameters when event fires
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AffectEquation {
    /// Left-hand side (variable to modify)
    pub lhs: String,

    /// Right-hand side (new value expression)
    pub rhs: Expr,
}

/// Continuous event that fires on zero-crossings
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ContinuousEvent {
    /// Human-readable identifier
    #[serde(skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,

    /// Condition expressions (zero-crossing detection)
    pub conditions: Vec<Expr>,

    /// What happens when the event fires on positive-going zero crossings
    pub affects: Vec<AffectEquation>,

    /// Separate affects for negative-going zero crossings
    #[serde(skip_serializing_if = "Option::is_none")]
    pub affect_neg: Option<Vec<AffectEquation>>,

    /// Root finding direction
    #[serde(skip_serializing_if = "Option::is_none")]
    pub root_find: Option<RootFindDirection>,

    /// Whether to reinitialize the system after the event
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reinitialize: Option<bool>,

    /// Brief description
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

// The 0.x `FunctionalAffect` descriptor is deliberately absent. esm 1.0.0 (RFC
// unified-variable-model D5) removed it along with the `discrete_parameters`
// event lists: a handler's only write channel was `modified_params`, so it now
// lives ON the parameter it writes as a `ParameterUpdate` carrying a
// [`FunctionalUpdate`] (`update.handler`), and events affect unknowns only.

/// Root finding direction for continuous events
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RootFindDirection {
    /// Detect positive-going zero crossings
    Left,
    /// Detect negative-going zero crossings
    Right,
    /// Detect all zero crossings
    All,
}
