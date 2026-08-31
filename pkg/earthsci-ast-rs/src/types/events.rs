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

    /// Functional affect specification
    #[serde(skip_serializing_if = "Option::is_none")]
    pub functional_affect: Option<FunctionalAffect>,

    /// Parameters modified by this event
    #[serde(skip_serializing_if = "Option::is_none")]
    pub discrete_parameters: Option<Vec<String>>,

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

    /// Parameters modified by this event
    #[serde(skip_serializing_if = "Option::is_none")]
    pub discrete_parameters: Option<Vec<String>>,

    /// Event priority (lower number = higher priority)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub priority: Option<u32>,

    /// Brief description
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

/// Functional affect specification for events
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FunctionalAffect {
    /// Registered identifier for the affect implementation
    pub handler_id: String,

    /// State variables accessed by the handler
    pub read_vars: Vec<String>,

    /// Parameters accessed by the handler
    pub read_params: Vec<String>,

    /// Parameters modified by the handler
    #[serde(skip_serializing_if = "Option::is_none")]
    pub modified_params: Option<Vec<String>>,

    /// Handler-specific configuration
    #[serde(skip_serializing_if = "Option::is_none")]
    pub config: Option<serde_json::Value>,
}

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

#[cfg(test)]
mod discrete_event_test {
    use super::*;

    #[test]
    fn test_discrete_event_fields_present() {
        // Test that we can create a DiscreteEvent with discrete_parameters and reinitialize
        let event = DiscreteEvent {
            name: Some("test_event".to_string()),
            trigger: DiscreteEventTrigger::Condition {
                expression: Expr::Number(1.0),
            },
            affects: None,
            functional_affect: None,
            discrete_parameters: Some(vec!["param1".to_string(), "param2".to_string()]),
            reinitialize: Some(true),
            description: Some("Test event".to_string()),
        };

        // Test serialization
        let json = serde_json::to_string(&event).expect("Serialization should work");
        assert!(
            json.contains("discrete_parameters"),
            "JSON should contain discrete_parameters field"
        );
        assert!(
            json.contains("reinitialize"),
            "JSON should contain reinitialize field"
        );
        assert!(
            json.contains("param1"),
            "JSON should contain the parameter values"
        );

        // Test deserialization
        let deserialized: DiscreteEvent =
            serde_json::from_str(&json).expect("Deserialization should work");

        assert_eq!(
            deserialized.discrete_parameters,
            Some(vec!["param1".to_string(), "param2".to_string()])
        );
        assert_eq!(deserialized.reinitialize, Some(true));
    }

    #[test]
    fn test_discrete_event_json_parsing() {
        let json = r#"
        {
            "trigger": {
                "type": "condition",
                "expression": 1.0
            },
            "discrete_parameters": ["param1", "param2"],
            "reinitialize": true
        }
        "#;

        let event: DiscreteEvent = serde_json::from_str(json)
            .expect("Should parse JSON with discrete_parameters and reinitialize");

        assert_eq!(
            event.discrete_parameters,
            Some(vec!["param1".to_string(), "param2".to_string()])
        );
        assert_eq!(event.reinitialize, Some(true));
    }
}
